import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(model: model, actions: actions)
            Divider().opacity(0.6)

            // Takes whatever the header and the hint bar leave over, so the list
            // scrolls inside a panel of fixed height instead of setting it. The
            // shortcut sheet is laid over this middle band rather than the whole
            // window: the search field and the hint bar are what the sheet is
            // explaining, so covering them would be answering the question by hiding it.
            ZStack {
                if model.results.isEmpty {
                    EmptyResults(hasQuery: !model.query.isEmpty, filter: model.filter)
                } else {
                    ResultList(model: model, actions: actions)
                }
                if model.showingShortcuts {
                    ShortcutsOverlay { model.showingShortcuts = false }
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.6)
            HintBar(model: model, actions: actions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Highlighting

/// Paints the search hits inside a string.
///
/// Everything is decided from ranges computed once per string, so a row costs one pass
/// over at most its 400-character preview. When nothing matched — a pinyin hit has no
/// literal position to point at — the string comes back in `plain` and the row simply
/// looks normal, which is better than dimming text for no visible reason.
private enum ClipHighlight {
    static func make(
        _ string: String,
        terms: [String],
        emphasis: Font,
        plain: Color,
        dimmed: Color,
        accent: Color
    ) -> AttributedString {
        func styled(_ slice: Substring, _ color: Color) -> AttributedString {
            var piece = AttributedString(slice)
            piece.foregroundColor = color
            return piece
        }

        let ranges = terms.isEmpty ? [] : ClipSearch.ranges(in: string, terms: terms)
        guard !ranges.isEmpty else { return styled(string[...], plain) }

        var result = AttributedString()
        var cursor = string.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result += styled(string[cursor..<range.lowerBound], dimmed)
            }
            var hit = styled(string[range], accent)
            hit.font = emphasis
            result += hit
            cursor = range.upperBound
        }
        if cursor < string.endIndex { result += styled(string[cursor...], dimmed) }
        return result
    }
}

// MARK: - Header

private struct SearchHeader: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("搜索剪贴板历史", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)

                if model.queueCount > 0 {
                    QueueBadge(count: model.queueCount, onClear: actions.clearQueue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)

            HStack(spacing: 6) {
                ForEach(PanelFilter.allCases) { filter in
                    FilterPill(filter: filter, selected: model.filter == filter) {
                        model.filter = filter
                    }
                }
                Spacer()
                if !model.checked.isEmpty {
                    Text("已选 \(model.checked.count) 条")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
        .onAppear { focused = true }
    }
}

private struct FilterPill: View {
    let filter: PanelFilter
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: filter.symbolName).font(.system(size: 10, weight: .semibold))
                Text(filter.label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(selected ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        // The pill's own label is an icon and a word; VoiceOver is told which of them is
        // switched on, which the colour alone conveys to everyone else.
        .accessibilityLabel(filter.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct QueueBadge: View {
    let count: Int
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "text.append").font(.system(size: 10, weight: .bold))
                Text("队列 \(count)").font(.system(size: 11, weight: .semibold))
            }
            // Combined so the icon is not announced as a separate empty element, and
            // spelled out because "队列 3" on its own does not say 3 of what.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("批量队列，\(count) 条")
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("清空队列（⌘⇧K）")
            .accessibilityLabel("清空队列")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
        .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Grouping

/// The bands the list is divided into.
///
/// Purely a drawing decision: the headers are inserted *inside* the same `ForEach` that
/// walks `results`, so a row's index in the flat array — which is what the selection,
/// the keyboard navigation and ⌘1-9 all speak in — is untouched by them.
private enum ClipGroup {
    case pinned
    case today
    case yesterday
    case thisWeek
    case earlier

    var title: String {
        switch self {
        case .pinned: return "收藏"
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .earlier: return "更早"
        }
    }

    /// Pinned entries sort above everything else regardless of age, so they are a band
    /// of their own rather than being scattered through the days they were copied on.
    static func of(_ record: ClipRecord, now: Date) -> ClipGroup {
        if record.pinned { return .pinned }
        let calendar = Calendar.current
        if calendar.isDateInToday(record.createdAt) { return .today }
        if calendar.isDateInYesterday(record.createdAt) { return .yesterday }
        // The current calendar week, which is what the label promises — a rolling seven
        // days would file last Sunday under 本周 on a Monday morning.
        if let week = calendar.dateInterval(of: .weekOfYear, for: now),
           week.contains(record.createdAt) {
            return .thisWeek
        }
        return .earlier
    }
}

private struct GroupHeader: View {
    let title: String
    let first: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, first ? 1 : 11)
            .padding(.bottom, 3)
            // So VoiceOver's rotor can jump band to band rather than row by row.
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - List

private struct ResultList: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    /// The kinds whose content is text, and so can be rewritten on the way out.
    private static let textual: Set<ClipKind> = [.text, .richText, .url]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, record in
                        // The header rides along with the row that opens the band rather
                        // than being an element of its own, so the enumeration the rest
                        // of the panel indexes into stays one row per element.
                        VStack(alignment: .leading, spacing: 2) {
                            if let group = header(at: index) {
                                GroupHeader(title: group.title, first: index == 0)
                            }
                            ResultRow(
                                record: record,
                                index: index,
                                selected: index == model.selectedIndex,
                                checked: model.checked.contains(record.id),
                                queued: model.isQueued(record.id),
                                queuePosition: model.queuePosition(at: index),
                                thumbnail: record.kind == .image ? model.thumbnail(for: record) : nil,
                                terms: model.highlightTerms,
                                context: model.contexts[record.id],
                                now: model.clockTick
                            )
                            .contentShape(Rectangle())
                            // On the row rather than on the wrapper, so the group header
                            // above it is not part of what gets dragged. `.onDrag` and a
                            // tap gesture coexist: the drag needs the pointer to travel
                            // before it takes over, so a stationary ⌘- or ⌥-click still
                            // reaches `activateRow`.
                            .onDrag { actions.dragBegan(record) }
                            // The selection follows the pointer, so what ↩ or a click
                            // acts on is always the row being looked at. On the row and
                            // not the wrapper, or the header above it would count as
                            // part of the row it introduces.
                            .onHover { inside in
                                if inside { actions.hoverIndex(index) } else { actions.hoverEnded(index) }
                            }
                            // What a click means depends on the modifiers held, and
                            // reading those is not something the view can do reliably —
                            // see `modifiersHeld()`. It reports the click and lets the
                            // controller decide.
                            .onTapGesture { actions.activateRow(index) }
                            .contextMenu {
                                Button("粘贴") { actions.selectIndex(index); actions.paste(false) }
                                Button("连续粘贴（不关闭）") {
                                    actions.selectIndex(index)
                                    actions.pasteKeepingOpen()
                                }
                                Button("以纯文本粘贴") { actions.selectIndex(index); actions.paste(true) }
                                // Only where there is text to rewrite. A picture has no
                                // upper case, and a file entry's paths are not the user's
                                // to reshape.
                                if Self.textual.contains(record.kind) {
                                    Menu("粘贴为…") {
                                        ForEach(PasteTransform.allCases) { transform in
                                            Button(transform.label) {
                                                actions.selectIndex(index)
                                                actions.pasteTransformed(transform)
                                            }
                                        }
                                    }
                                }
                                Button("只复制，不粘贴") { actions.selectIndex(index); actions.copyOnly() }
                                // Rich text is left out on purpose: saving would flatten
                                // it to plain text, and silently losing the styling is not
                                // something an "编辑…" should do.
                                if record.kind == .text || record.kind == .url,
                                   !record.oversized {
                                    Button("编辑…") { actions.selectIndex(index); actions.edit() }
                                }
                                Divider()
                                // On the queue tab the useful queue actions are the ones
                                // that reorder it; "加入批量队列" there would only move the
                                // row to the end, which is not what anyone means by it.
                                if model.filter == .queue {
                                    Button("移出队列") { actions.removeFromQueue(record.id) }
                                    Button("上移") { actions.moveInQueue(record.id, true) }
                                    Button("下移") { actions.moveInQueue(record.id, false) }
                                } else {
                                    Button("加入批量队列") { actions.selectIndex(index); actions.enqueue() }
                                }
                                Button(record.pinned ? "取消收藏" : "收藏") {
                                    actions.selectIndex(index)
                                    actions.togglePin()
                                }
                                Divider()
                                Button("删除", role: .destructive) {
                                    actions.selectIndex(index)
                                    actions.delete()
                                }
                            }
                        }
                        .id(record.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            // Keyed to `scrollTick`, not to the selection itself: the pointer moves the
            // selection too, and scrolling for that would slide the hovered row out
            // from under the pointer, hover whichever row replaced it, and scroll again.
            .onChange(of: model.scrollTick) { _ in
                guard let record = model.selected else { return }
                guard !model.reduceMotion else {
                    proxy.scrollTo(record.id, anchor: .center)
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(record.id, anchor: .center)
                }
            }
        }
    }

    /// The band a row opens, or nil when it continues the one above.
    ///
    /// Suppressed while there is a query: search results come back in relevance order,
    /// where a date boundary is noise rather than structure. Suppressed on the queue tab
    /// for the same reason — the order there is the paste order, and "今天" cutting
    /// through it would suggest a grouping the list does not have.
    private func header(at index: Int) -> ClipGroup? {
        guard model.query.isEmpty, model.filter != .queue,
              model.results.indices.contains(index) else { return nil }
        let group = ClipGroup.of(model.results[index], now: model.clockTick)
        guard index > 0 else { return group }
        return ClipGroup.of(model.results[index - 1], now: model.clockTick) == group ? nil : group
    }
}

private struct ResultRow: View {
    let record: ClipRecord
    let index: Int
    let selected: Bool
    let checked: Bool
    let queued: Bool
    /// Set only on the queue tab: the row's place in the dispensing order, which is also
    /// the digit ⌘n reaches it by.
    let queuePosition: Int?
    let thumbnail: NSImage?
    let terms: [String]
    /// Set when the hit is not visible in the preview, and this snippet is why the row
    /// is in the list at all — so it takes the subtitle's place rather than sitting
    /// alongside it.
    let context: String?
    /// The reference date for "3 分钟前". Passed in rather than read here so the whole
    /// list ages together, and so a row redraws when the panel's clock moves on.
    let now: Date

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let queuePosition {
                Text("\(queuePosition)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                    .frame(width: 15, alignment: .trailing)
            }

            leading
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            trailing
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    checked && !selected ? Color.accentColor.opacity(0.7) : .clear,
                    lineWidth: 1.5
                )
        )
        .onHover { hovering = $0 }
        // One element per row, or VoiceOver would walk the icon, the two labels and each
        // badge separately and never say what the row *is*.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// What VoiceOver reads: what kind of thing it is, what it says, where it came from
    /// and how long ago — in that order, because the first two are what identifies the
    /// row and the rest only tells them apart.
    private var spokenLabel: String {
        var parts: [String] = []
        if let queuePosition { parts.append("队列第 \(queuePosition) 条") }
        parts.append(record.kind.label)
        parts.append(record.displayTitle)
        if let name = record.sourceName, !name.isEmpty { parts.append(name) }
        parts.append(ClipRecord.relativeTime(from: record.createdAt, to: now))
        if record.pinned { parts.append("已收藏") }
        if checked { parts.append("已选中") }
        if queued, queuePosition == nil { parts.append("在队列中") }
        return parts.joined(separator: "，")
    }

    private var title: AttributedString {
        ClipHighlight.make(
            record.displayTitle,
            terms: terms,
            emphasis: .system(size: 13, weight: .semibold),
            plain: selected ? .white : .primary,
            // On the selected row the fill *is* the accent colour, so the hit cannot be
            // picked out by hue; it is the surrounding text that gives way instead.
            dimmed: selected ? .white.opacity(0.7) : .primary,
            accent: selected ? .white : .accentColor
        )
    }

    private var subtitle: AttributedString {
        guard let context else {
            var text = AttributedString(record.subtitle(now: now))
            text.foregroundColor = selected ? .white.opacity(0.75) : .secondary
            return text
        }
        return ClipHighlight.make(
            context,
            terms: terms,
            emphasis: .system(size: 10.5, weight: .semibold),
            plain: selected ? .white.opacity(0.75) : .secondary,
            dimmed: selected ? .white.opacity(0.75) : .secondary,
            accent: selected ? .white : .accentColor
        )
    }

    private var background: Color {
        if selected { return .accentColor }
        if checked { return .accentColor.opacity(0.12) }
        if hovering { return .secondary.opacity(0.10) }
        return .clear
    }

    /// The colour a colour entry paints, for the rows that have one.
    private var swatch: Color? {
        guard record.kind == .color, let hex = record.colorHex,
              let value = ClipColorValue(hex: hex)
        else { return nil }
        return Color(nsColor: value.nsColor)
    }

    /// A picture is a picture, a colour is its colour, and everything else shows the
    /// application it came from — which is how people remember what they copied far
    /// more often than by its type. The type survives as a corner badge.
    @ViewBuilder
    private var leading: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        } else if let swatch {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(swatch)
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                )
        } else if let icon = AppIconCache.shared.appIcon(bundleID: record.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 27, height: 27)
                .frame(width: 34, height: 34)
                .overlay(alignment: .bottomTrailing) { kindBadge }
        } else {
            glyphTile
        }
    }

    private var glyphTile: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.13))
            .overlay(
                Image(systemName: record.kind.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            )
    }

    /// Opaque rather than translucent: it sits on the application icon's own corner,
    /// and a badge you can see the icon through is not a badge.
    private var kindBadge: some View {
        Image(systemName: record.kind.symbolName)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(width: 13, height: 13)
            .background(
                Circle().fill(selected ? Color.white : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .offset(x: 1, y: 1)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 5) {
            if record.oversized {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.orange)
                    .help("这条内容超过了单条上限，没有保存正文")
            }
            // Both of these are about the queue, and on the queue tab every row is in it:
            // the leading number already says so, and says where.
            if queued, queuePosition == nil {
                Image(systemName: "text.append")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
            }
            if record.pinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white : Color.orange)
            }
            // The queue tab's leading number is the same digit; two of them on one row
            // would read as two different positions.
            if index < 9, queuePosition == nil {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
                    .opacity(selected || hovering ? 1 : 0.45)
            }
        }
    }
}

// MARK: - Preview pane

/// The root of the preview window beside the list. Hovering a row is what opens it.
struct ClipboardPreviewView: View {
    @ObservedObject var model: ClipboardPanelModel
    @State private var text: PreviewText?
    /// Built alongside the text rather than in `body`, because the attributed copy of a
    /// long document is not something to rebuild on every layout pass.
    @State private var highlighted: AttributedString?

    var body: some View {
        Group {
            if let record = model.previewRecord {
                VStack(alignment: .leading, spacing: 0) {
                    content(for: record)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider().opacity(0.6)
                    metadata(for: record)
                }
                // Keyed on the query too: the same record has to be re-marked when what
                // it was matched by changes.
                .task(id: loadKey(record)) {
                    text = nil
                    highlighted = nil
                    // Sweeping the pointer down the list changes the previewed row many
                    // times a second. Without this pause each row crossed would cost a
                    // disk read and a full text layout on the way past.
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard !Task.isCancelled else { return }
                    let loaded = await model.previewText(for: record)
                    guard !Task.isCancelled else { return }
                    text = loaded
                    // The preview is already capped at a couple of thousand characters,
                    // so marking it up is cheap enough to do right here.
                    if let loaded, !model.highlightTerms.isEmpty {
                        highlighted = ClipHighlight.make(
                            loaded.body,
                            terms: model.highlightTerms,
                            emphasis: .system(size: 12.5, weight: .semibold),
                            plain: .primary,
                            dimmed: .primary,
                            accent: .accentColor
                        )
                    }
                }
            } else {
                Color.clear
            }
        }
        .onHover { model.setPointerInPreview($0) }
    }

    private func loadKey(_ record: ClipRecord) -> String {
        record.id.uuidString + "\u{1}" + model.highlightTerms.joined(separator: " ")
    }

    @ViewBuilder
    private func content(for record: ClipRecord) -> some View {
        if record.oversized {
            notice(
                "这条内容超过了单条上限",
                detail: "当时只记下了它的信息，正文没有保存，所以无法粘贴回去。可以在设置里调高上限。",
                symbol: "exclamationmark.triangle"
            )
        } else if record.kind == .image {
            if let image = model.thumbnail(for: record) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            } else {
                notice("图片", detail: "没有生成预览。", symbol: "photo")
            }
        } else if let value = colorValue(record) {
            ColorPreview(value: value, model: model)
        } else if record.kind == .url {
            // No wait for the payload: the stored preview line already *is* the URL, so
            // the pane can be right on the first frame instead of blank for 60ms.
            URLPreview(urlString: text?.body ?? record.preview)
        } else if record.kind == .files, let text, !text.body.isEmpty {
            FilePreview(text: text, terms: model.highlightTerms)
        } else if let text, !text.body.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(highlighted ?? AttributedString(text.body))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if text.truncated {
                        Text("预览已截断 · 粘贴的仍是完整内容")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
            }
        } else if text == nil {
            // Still loading. Blank rather than a spinner: at 60ms the spinner would
            // flash on and off again on every row the pointer crosses.
            Color.clear
        } else {
            notice("没有可预览的文本", detail: record.preview, symbol: record.kind.symbolName)
        }
    }

    private func notice(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func colorValue(_ record: ClipRecord) -> ClipColorValue? {
        guard record.kind == .color, let hex = record.colorHex else { return nil }
        return ClipColorValue(hex: hex)
    }

    /// Counted from what the preview already loaded, never from the payload: one line of
    /// metadata is not worth reading a megabyte back off disk. Past the preview cap the
    /// honest answer is a lower bound, so that is what it says.
    private func textStats(for record: ClipRecord) -> String? {
        guard [ClipKind.text, .richText, .url].contains(record.kind),
              let text, !text.body.isEmpty
        else { return nil }
        guard !text.truncated else { return "超过 \(text.body.count) 字符" }
        let lines = text.body.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(text.body.count) 字符 · \(lines) 行"
    }

    private func metadata(for record: ClipRecord) -> some View {
        HStack(spacing: 6) {
            Label(record.kind.label, systemImage: record.kind.symbolName)
            if let name = record.sourceName, !name.isEmpty {
                Text("·")
                if let icon = AppIconCache.shared.appIcon(bundleID: record.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(name)
            }
            if let stats = textStats(for: record) {
                Text("·")
                Text(stats)
            }
            if record.byteSize > 0 {
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteSize), countStyle: .file))
            }
            Spacer(minLength: 6)
            Text(record.createdAt, style: .time)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Preview panes

/// A colour big enough to judge, and the three notations people go on to paste.
private struct ColorPreview: View {
    let value: ClipColorValue
    @ObservedObject var model: ClipboardPanelModel

    private var formats: [(name: String, text: String)] {
        [("HEX", value.hexString), ("RGB", value.rgbString), ("HSL", value.hslString)]
    }

    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: value.nsColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .frame(height: 160)

            VStack(spacing: 6) {
                ForEach(formats, id: \.name) { format in
                    HStack(spacing: 8) {
                        Text(format.name)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .leading)
                        Text(format.text)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 6)
                        Button {
                            model.copyPlainString(format.text)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                // Without a filled shape behind it only the glyph's own
                                // strokes are clickable, which makes a 11pt icon a very
                                // small target.
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("复制 \(format.name)")
                        .accessibilityLabel("复制 \(format.name)")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// The domain first, because that is what identifies a link at a glance, then the whole
/// thing for the cases where the path is the point.
private struct URLPreview: View {
    let urlString: String

    private var trimmed: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Through `URLComponents` rather than `URL.host`, which is the deprecated half of
    /// the newer parsing API.
    private var host: String? {
        URLComponents(string: trimmed)?.host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(host ?? "链接")
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(trimmed)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let url = URL(string: trimmed) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("在浏览器打开", systemImage: "safari")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在浏览器打开这个链接")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// A file entry as Finder would show it, rather than as a column of paths.
private struct FilePreview: View {
    private let rows: [Row]
    private let overflow: Int

    /// The pane is a glance, not a file manager. Fifty rows is already several
    /// screenfuls, and each one costs an icon lookup and a stat.
    private static let maxRows = 50

    private struct Row: Identifiable {
        let id: Int
        let path: String
        /// Marked up here rather than in `body`: the hit inside a long path is exactly
        /// what the search was for, and a name shown plain would look like a miss.
        let name: AttributedString
        let directory: AttributedString
        let missing: Bool
    }

    init(text: PreviewText, terms: [String]) {
        var lines = text.body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        // A cut at 2,000 characters can land in the middle of a path, and half a path is
        // worse than one row fewer.
        if text.truncated, lines.count > 1 { lines.removeLast() }
        overflow = max(0, lines.count - Self.maxRows)

        let fm = FileManager.default
        rows = lines.prefix(Self.maxRows).enumerated().map { index, path in
            let url = URL(fileURLWithPath: path)
            let missing = !fm.fileExists(atPath: path)
            return Row(
                id: index,
                path: path,
                name: ClipHighlight.make(
                    url.lastPathComponent,
                    terms: terms,
                    emphasis: .system(size: 12.5, weight: .semibold),
                    plain: missing ? .red : .primary,
                    dimmed: missing ? .red : .primary,
                    accent: .accentColor
                ),
                directory: ClipHighlight.make(
                    url.deletingLastPathComponent().path,
                    terms: terms,
                    emphasis: .system(size: 10, weight: .semibold),
                    plain: .secondary,
                    dimmed: .secondary,
                    accent: .accentColor
                ),
                missing: missing
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(nsImage: AppIconCache.shared.fileIcon(path: row.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                            .opacity(row.missing ? 0.45 : 1)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(row.name)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if row.missing {
                                    Text("已不存在")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(Color.red)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(Color.red.opacity(0.14))
                                        )
                                }
                            }
                            Text(row.directory)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                }

                if overflow > 0 {
                    Text("还有 \(overflow) 个文件没有列出")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

// MARK: - Empty / hints

private struct EmptyResults: View {
    let hasQuery: Bool
    let filter: PanelFilter

    var body: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: hasQuery ? "magnifyingglass" : symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasQuery ? "没有匹配的内容" : title)
                .font(.system(size: 13, weight: .medium))
            if !hasQuery {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch filter {
        case .pinned: return "star"
        case .queue: return "text.append"
        default: return "clipboard"
        }
    }

    private var title: String {
        switch filter {
        case .pinned: return "还没有收藏任何内容"
        case .queue: return "队列是空的"
        default: return "剪贴板历史是空的"
        }
    }

    private var detail: String {
        switch filter {
        case .pinned:
            return "选中一条按 ⌘P 就能收藏，收藏的内容不会被自动清理。"
        case .queue:
            return "Hyper+Q 把选中的内容收进队列，Hyper+V 按顺序一条条粘贴出来。\n面板里选中一条按 ⌥↩ 也能加进来。"
        default:
            return "复制点什么，它就会出现在这里。"
        }
    }
}

/// One key and what it does, as the hint bar and the shortcut sheet both draw it.
private struct KeyCap: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }
}

private struct HintBar: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    /// Kept to what fits the list's width on one line, and to what applies *now* — a bar
    /// that always said the same three things would be describing the panel rather than
    /// the situation. Everything it leaves out is one `?` away.
    ///
    /// Ordered most specific first: a multi-selection is something the user is in the
    /// middle of, and the way out of it matters more than which tab it happens on.
    private var hints: [(String, String)] {
        if !model.checked.isEmpty {
            return [("↩", "合并粘贴"), ("⌘⌫", "删除"), ("Esc", "取消多选")]
        }
        if model.filter == .queue {
            return [("↩", "粘贴"), ("⌘⌫", "移出队列"), ("⌘⇧K", "清空队列")]
        }
        if !model.query.isEmpty {
            return [("↩", "粘贴"), ("Esc", "清空搜索")]
        }
        return [("↩", "粘贴"), ("⌘点击", "连续粘贴"), ("⌥点击", "多选")]
    }

    /// The `?` is only offered where it is also the key that works: with something typed
    /// in the field, `?` is a character rather than a shortcut.
    private var offersShortcuts: Bool { model.query.isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(hints, id: \.0) { key, label in
                KeyCap(key: key, label: label)
            }
            if offersShortcuts {
                Button(action: actions.toggleShortcuts) {
                    KeyCap(key: "?", label: "快捷键")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快捷键速查")
            }
            Spacer()
            Text("\(model.results.count) 条")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// Everything the panel answers to, over the list.
///
/// A sheet rather than a longer hint bar: the full set is two dozen entries, and the bar
/// has room for three. It covers the list because that is the only space a panel of
/// fixed size has to give — and because the list is exactly what you stop looking at
/// while you look one of these up.
private struct ShortcutsOverlay: View {
    let dismiss: () -> Void

    private static let entries: [(String, String)] = [
        ("↩", "粘贴"),
        ("⌘↩", "以纯文本粘贴"),
        ("⌥↩", "加入队列"),
        ("⌘1-9", "粘贴第 n 条"),
        ("↑ ↓", "上下移动"),
        ("⇧↑ ⇧↓", "多选"),
        ("Tab", "切换过滤"),
        ("⌘P", "收藏 / 取消"),
        ("⌘C", "只复制，不粘贴"),
        ("⌘⌫", "删除（队列页：移出队列）"),
        ("⌘⇧K", "清空队列"),
        ("Esc", "清空搜索 / 关闭"),
        ("⌘点击", "连续粘贴，面板不关"),
        ("⌥点击", "多选"),
        ("拖拽", "把内容拖出面板"),
        ("右键", "更多操作"),
    ]

    /// Split down the middle rather than laid out row-first, so each column reads top to
    /// bottom the way a list of keys is looked at.
    private var columns: ([(String, String)], [(String, String)]) {
        let half = (Self.entries.count + 1) / 2
        return (Array(Self.entries.prefix(half)), Array(Self.entries.dropFirst(half)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷键")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 18) {
                column(columns.0)
                column(columns.1)
            }

            Spacer(minLength: 0)

            Text("再按一次 ? 或 Esc 关闭")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        // The whole layer is the dismiss target, and it has to swallow the clicks it
        // does not use — a click that fell through would paste the row underneath.
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
    }

    private func column(_ entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(entries, id: \.0) { key, label in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.secondary.opacity(0.18))
                        )
                        // Fixed so the descriptions line up into a column of their own.
                        .frame(width: 56, alignment: .leading)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(key)，\(label)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
