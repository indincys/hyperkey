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
                    ShortcutsOverlay(returnPastes: model.returnPastes) {
                        model.showingShortcuts = false
                    }
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

                // Above the pills rather than beside them: seven pills is exactly as much
                // as the panel's width holds, and anything added to that row costs the
                // labels their second character. Here it sits with the other badge, in
                // the row the eye starts on.
                if let name = model.targetAppName {
                    PasteTargetBadge(name: name, icon: model.targetAppIcon)
                }
                if model.queueCount > 0 {
                    QueueBadge(count: model.queueCount, onClear: actions.clearQueue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)

            HStack(spacing: 0) {
                FilterPills(model: model)
                // The count that used to sit here has moved into the batch bar at the
                // bottom, next to the things it can be acted on with. The spacer is
                // outside `FilterPills` on purpose — see what it measures.
                Spacer(minLength: 0)
            }
            // Tighter than the row above it, because this one is full: see `FilterPills`
            // for what seven pills and their numbers actually measure.
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .onAppear { focused = true }
    }
}

/// The seven tabs, each wearing how many rows it holds under the query in the field.
///
/// The icons are gone from this row, which was not a free choice. Measured with
/// `NSHostingView.fittingSize` at the three panel widths: seven pills of icon plus
/// two-CJK label already wanted 443pt against the 372pt the standard 400pt panel had for
/// them — so the labels were being *wrapped down the middle*, 全 over 部, before a single
/// digit was added. With numbers on top it is 565pt. Dropping the icon buys back 17pt a
/// pill; dropping it only from the unselected ones was no good either, fitting no better
/// at 418pt and re-flowing the whole row every time the selection moved between pills of
/// different widths. The labels are what survives, because 全部 / 收藏 / 队列 / 文本 / 链接
/// / 图片 / 文件 already say what they are and a 10pt glyph only decorates that. The icons
/// live on in the empty states, which is where someone genuinely needs telling.
///
/// Even bare, the numbers do not always fit: 300pt of labels, plus up to 120pt of digits
/// once the history reaches its thousand-entry ceiling, against 380pt at the standard
/// width and 340 at the compact one. `minimumScaleFactor` is no answer — rendered and
/// read back, a crowded `HStack` truncates its labels to 全… rather than scaling them.
/// So the row is offered at four densities and `ViewThatFits` takes the first that does
/// fit: the counts thin out and finally go, but a label is never cut.
///
/// What that works out to, rendered at each panel size and read back: the large panel
/// keeps the numbers under any history; the standard one keeps them up to a four-digit
/// 全部 and gives them up only past that; the compact one has room for them only while
/// the history is small, and otherwise shows the labels alone — which is all it showed
/// before this, and at least it no longer breaks them in half to do it.
///
/// The trailing spacer belongs to the caller. Inside these candidates it would be
/// infinitely compressible, every one of them would "fit", and the first would always
/// win — measuring nothing at all.
private struct FilterPills: View {
    @ObservedObject var model: ClipboardPanelModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(countSize: 10, hpad: 8, spacing: 5)
            row(countSize: 10, hpad: 6, spacing: 4)
            // A smaller number is still a number; this is the last rung that keeps them.
            row(countSize: 9, hpad: 6, spacing: 3)
            row(countSize: nil, hpad: 8, spacing: 5)
        }
    }

    private func row(countSize: CGFloat?, hpad: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(PanelFilter.allCases) { filter in
                FilterPill(
                    filter: filter,
                    selected: model.filter == filter,
                    count: model.count(for: filter),
                    countSize: countSize,
                    hpad: hpad
                ) {
                    model.filter = filter
                }
            }
        }
    }
}

private struct FilterPill: View {
    let filter: PanelFilter
    let selected: Bool
    let count: Int
    /// The size the number is drawn at, or nothing where the row had to give it up.
    let countSize: CGFloat?
    let hpad: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(filter.label)
                    .font(.system(size: 11, weight: .medium))
                // A row of zeros would be seven pieces of furniture saying nothing, so a
                // tab with nothing in it just wears its name.
                if let countSize, count > 0 {
                    Text("\(count)")
                        .font(.system(size: countSize, weight: .medium))
                        .foregroundStyle(
                            selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6)
                        )
                }
            }
            .lineLimit(1)
            .padding(.horizontal, hpad)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(selected ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        // Spelled out, because "文本 260" on its own does not say 260 of what — and which
        // pill is switched on, which the colour alone conveys to everyone else. Spoken
        // whether or not the row had room to draw it: VoiceOver has no width problem.
        .accessibilityLabel(count > 0 ? "\(filter.label)，\(count) 条" : "\(filter.label)，没有内容")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Where ↩ is aimed.
///
/// The panel floats over an application that never stopped being active, and which one
/// that is stops being obvious the moment anything else has happened in between — a
/// second monitor, a full-screen space, a panel reopened after an edit. Naming it costs
/// one badge and removes the only real hesitation before pressing Return.
private struct PasteTargetBadge: View {
    let name: String
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(name)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        // Long application names are not worth crowding out the field you type in.
        .frame(maxWidth: 120, alignment: .trailing)
        .help("按 ↩ 将粘贴到这里")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("按回车键将粘贴到 \(name)")
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

/// The band label above the row that opens it. Which rows those are is decided by the
/// model — see `ClipboardPanelModel.groupHeaders`.
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
                            if let title = model.groupHeaders[index] {
                                GroupHeader(title: title, first: index == 0)
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
                                now: model.clockTick,
                                reduceMotion: model.reduceMotion,
                                onPin: { actions.togglePinRow(index) },
                                onDelete: { actions.deleteRow(index) }
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
                        // Rows arrive and leave for reasons the list cannot show any
                        // other way — a deletion, an undo, a copy made in another
                        // application while the panel is up. Sliding in from above says
                        // where a new entry went; fading out says the row under the
                        // pointer is the one that just went. Only ever animated from
                        // `apply`, so rows the lazy stack materialises while scrolling
                        // are not transitioned in as though they were new.
                        .transition(
                            model.reduceMotion
                                ? .identity
                                : .opacity.combined(with: .move(edge: .top))
                        )
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
    let reduceMotion: Bool
    /// The hover buttons. One row each, never the ticked set — see `act(onRow:_:)`.
    let onPin: () -> Void
    let onDelete: () -> Void

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
                    .font(.system(size: 13, design: design))
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
                // Only on the selection, and only just long enough to be followed: ↑↓
                // held down walks the list faster than any longer fade could keep up
                // with. Hover is deliberately left instant — the highlight has to be
                // under the pointer by the time the eye arrives, and a sweep down the
                // list would otherwise leave a comet's tail of half-lit rows.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
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
        // The hover buttons carry their own labels, but a combined row absorbs its
        // children — and VoiceOver never hovers anything, so buttons that only exist
        // under a pointer would be unreachable however they were labelled. Offered as
        // actions on the row instead, which is where a rotor looks for them.
        .accessibilityAction(named: record.pinned ? "取消收藏" : "收藏", onPin)
        .accessibilityAction(named: "删除", onDelete)
    }

    /// What VoiceOver reads: what kind of thing it is, what it says, where it came from
    /// and how long ago — in that order, because the first two are what identifies the
    /// row and the rest only tells them apart.
    private var spokenLabel: String {
        var parts: [String] = []
        if let queuePosition { parts.append("队列第 \(queuePosition) 条") }
        parts.append(record.kind.label)
        parts.append(record.preview)
        if let name = record.sourceName, !name.isEmpty { parts.append(name) }
        parts.append(ClipRecord.relativeTime(from: record.createdAt, to: now))
        if record.pinned { parts.append("已收藏") }
        if checked { parts.append("已选中") }
        if queued, queuePosition == nil { parts.append("在队列中") }
        return parts.joined(separator: "，")
    }

    /// Code, JSON and paths are drawn in a monospaced face wherever they are shown: the
    /// alignment is part of what they say, and a proportional font quietly deforms it.
    /// Set on the whole line rather than per run, or the search hits inside it would be
    /// the one part of the row in a different typeface.
    private var design: Font.Design {
        record.contentTag?.prefersMonospace == true ? .monospaced : .default
    }

    private var title: AttributedString {
        ClipHighlight.make(
            record.preview,
            terms: terms,
            emphasis: .system(size: 13, weight: .semibold, design: design),
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
                // The stored thumbnail is 720px on its longest side and this draws it at
                // 34pt, so every row is a 20× reduction. At the default interpolation
                // that lands as aliased noise — a screenshot of text turns into speckle.
                .interpolation(.high)
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
            rowEnd
        }
    }

    /// The right-hand end of the row, which the pointer takes over.
    ///
    /// The star and the ⌘n cap are what the row says about itself; the two buttons are
    /// what can be done to it, and there is only room for one of those at a time. The
    /// buttons stand in for exactly the pair they replace — the star button *is* the
    /// pinned marker, filled when it is pinned — so nothing is hidden that the pointer
    /// has not already made reachable. The width is fixed across both states so the title
    /// beside it does not re-wrap the moment the pointer crosses the row, which is the
    /// one thing that would make a list unreadable to sweep down.
    ///
    /// The ⌘n cap is the piece that genuinely gives way, and it is the right one: it
    /// belongs to the keyboard, and the pointer being on the row is proof the keyboard is
    /// not what is being used.
    private var rowEnd: some View {
        Group {
            if hovering {
                HStack(spacing: 2) {
                    RowActionButton(
                        symbol: record.pinned ? "star.fill" : "star",
                        label: record.pinned ? "取消收藏" : "收藏",
                        hint: "收藏 / 取消收藏（⌘P）",
                        tint: record.pinned ? .orange : nil,
                        onSelectedRow: selected,
                        action: onPin
                    )
                    RowActionButton(
                        symbol: "trash",
                        label: "删除",
                        hint: "删除这一条（⌘Z 可撤销）",
                        tint: nil,
                        onSelectedRow: selected,
                        action: onDelete
                    )
                }
            } else {
                HStack(spacing: 5) {
                    if record.pinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(selected ? Color.white : Color.orange)
                    }
                    // The queue tab's leading number is the same digit; two of them on
                    // one row would read as two different positions.
                    if index < 9, queuePosition == nil {
                        Text("⌘\(index + 1)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(
                                selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7)
                            )
                            .opacity(selected ? 1 : 0.45)
                    }
                }
            }
        }
        .frame(width: 42, alignment: .trailing)
    }
}

/// One of the two buttons that surface at the end of a row under the pointer.
///
/// A view of its own for the hover highlight: a target this small needs to say it is a
/// target before it is clicked, and that takes a piece of state per button.
private struct RowActionButton: View {
    let symbol: String
    let label: String
    let hint: String
    let tint: Color?
    /// The selected row is painted in the accent colour, so nothing on it can be tinted —
    /// it is the one place these have to go white like everything else.
    let onSelectedRow: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(onSelectedRow ? Color.white : (tint ?? Color.secondary))
                // Without a filled shape behind it only the glyph's own strokes take the
                // click, which is a very small target for a 12pt icon.
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(
                        hovering
                            ? (onSelectedRow
                                ? Color.white.opacity(0.22)
                                : Color.secondary.opacity(0.22))
                            : Color.clear
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(hint)
        .accessibilityLabel(label)
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
    /// The styled rendering of an RTF entry, when there is one. Nil for everything else,
    /// and for the styled entries that were too large or failed to parse — those fall
    /// through to the plain-text pane below.
    @State private var rich: ClipRichText.Rendered?

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
                    rich = nil
                    // Sweeping the pointer down the list changes the previewed row many
                    // times a second. Without this pause each row crossed would cost a
                    // disk read and a full text layout on the way past.
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard !Task.isCancelled else { return }
                    let loaded = await model.previewText(for: record)
                    guard !Task.isCancelled else { return }
                    // Before `text` is published rather than after, so a styled entry
                    // does not show one frame of flat text and then redraw itself into
                    // the styled card. Until both have landed the pane stays blank,
                    // which is what it does for every other row too.
                    if let data = await model.richTextData(for: record) {
                        guard !Task.isCancelled else { return }
                        rich = ClipRichText.render(data)
                    }
                    guard !Task.isCancelled else { return }
                    text = loaded
                    // The preview is already capped at a couple of thousand characters,
                    // so marking it up is cheap enough to do right here.
                    if let loaded, !model.highlightTerms.isEmpty {
                        highlighted = ClipHighlight.make(
                            loaded.body,
                            terms: model.highlightTerms,
                            emphasis: .system(size: 12.5, weight: .semibold, design: design(record)),
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
                ImagePreview(image: image) { model.openImageExternally(record) }
            } else {
                notice("图片", detail: "没有生成预览。", symbol: "photo")
            }
        } else if let rich, record.kind == .richText {
            RichTextPreview(rendered: rich)
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
                        .font(.system(size: 12.5, design: design(record)))
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

    /// Same rule as the row's: what the content tag says the text is decides the face it
    /// is drawn in, here and in the list, so an entry does not change typeface on the way
    /// into its own preview.
    private func design(_ record: ClipRecord) -> Font.Design {
        record.contentTag?.prefersMonospace == true ? .monospaced : .default
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
            // Beside the kind, because it is a second reading of the same question — and
            // because it is what explains the monospaced face the pane above is using.
            if let tag = record.contentTag {
                Text("·")
                Label(tag.label, systemImage: tag.symbolName)
            }
            // The row's subtitle says this too, but the row is gone from view the moment
            // the pointer crosses into the preview — and dimensions are exactly what a
            // picture is looked up for.
            if record.kind == .image, let w = record.pixelWidth, let h = record.pixelHeight {
                Text("·")
                Text("\(w)×\(h)")
            }
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

/// The picture, and the two things anyone wants next: the original bytes on the
/// clipboard, or the whole thing open somewhere it can be looked at properly.
private struct ImagePreview: View {
    let image: NSImage
    let openExternally: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                // The stored thumbnail is 720px on its longest side and this pane is
                // usually wider than that, so the picture is being scaled *up* as often
                // as down — which is exactly where the default interpolation shows.
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Button(action: openExternally) {
                    Label("在预览程序中打开", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("把原图写到临时文件后交给「预览」打开")
                .accessibilityLabel("在预览程序中打开这张图片")

                // Worth saying because the pane shows a downscaled copy: the key puts the
                // *original* on the clipboard, not what is on screen here.
                Text("⌘C 复制原图")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }
}

/// An RTF entry as it was styled, rather than as the characters under the styling.
private struct RichTextPreview: View {
    let rendered: ClipRichText.Rendered

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(rendered.text)
                    // Whatever the runs do not set. RTF from a word processor names a
                    // font for every run; RTF from a web page frequently names none.
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.black)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    // A page of its own, in paper white, whatever the app's appearance.
                    // RTF carries its own colours and they were chosen against a light
                    // background — dark grey on dark grey is the usual result of letting
                    // them sit on the panel's material, and the styling is the entire
                    // point of this pane.
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )

                if rendered.truncated {
                    Text("预览已截断 · 粘贴的仍是完整内容")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
    }
}

/// Turns an entry's RTF into something `Text` can draw.
///
/// The search highlighting is deliberately given up here: marking hits means rewriting
/// the run of text they fall in, which would overwrite the very styling this pane exists
/// to show. Of the two, the styling is what the plain-text pane cannot do — and a styled
/// entry found by search still shows its hit highlighted in the row that led here.
private enum ClipRichText {
    struct Rendered {
        var text: AttributedString
        var truncated: Bool
    }

    /// Same cap as the plain-text preview, for the same reason: `Text` lays out every
    /// character before it draws the first line, and the cost grows faster than the
    /// length. See `ClipboardPanelModel.previewCharacterCap`.
    private static let characterCap = 2_000

    /// Main-thread only — `NSAttributedString(rtf:)` is AppKit's parser. The caller keeps
    /// it behind the preview's debounce and its own size cap.
    static func render(_ data: Data) -> Rendered? {
        guard let parsed = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }
        let truncated = parsed.length > characterCap
        let slice = truncated
            ? parsed.attributedSubstring(from: NSRange(location: 0, length: characterCap))
            : parsed
        guard !slice.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Rebuilt run by run rather than handed over wholesale: converting an
        // `NSAttributedString` leaves its font and colour in AppKit's attribute scope,
        // and what `Text` draws from is SwiftUI's. This is the translation between them,
        // and it is bounded by the cap above.
        var result = AttributedString()
        slice.enumerateAttributes(
            in: NSRange(location: 0, length: slice.length), options: []
        ) { attributes, range, _ in
            var piece = AttributedString(slice.attributedSubstring(from: range).string)
            if let font = attributes[.font] as? NSFont { piece.font = Font(font) }
            if let color = attributes[.foregroundColor] as? NSColor {
                piece.foregroundColor = Color(nsColor: color)
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                piece.underlineStyle = .single
            }
            result += piece
        }
        return Rendered(text: result, truncated: truncated)
    }
}

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

/// The pane where the list would be.
///
/// An empty tab is not a failure but a question — "is this thing on?" — and the tabs are
/// each empty for a different reason. So each one answers for itself: what belongs here,
/// and what would put something in it. An empty search is the one case that is about the
/// query rather than the tab, and it says so instead.
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
            if let detail = hasQuery ? searchDetail : detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch filter {
        case .all: return "clipboard"
        case .pinned: return "star"
        case .queue: return "text.append"
        // The same glyph the tab used to wear, which is where it earns its keep: this is
        // the one moment someone is actually asking what a tab is for.
        default: return filter.symbolName
        }
    }

    private var title: String {
        switch filter {
        case .all: return "剪贴板历史是空的"
        case .pinned: return "还没有收藏任何内容"
        case .queue: return "队列是空的"
        case .text: return "还没有复制过文本"
        case .url: return "还没有复制过链接"
        case .image: return "还没有复制过图片"
        case .files: return "还没有复制过文件"
        }
    }

    private var detail: String? {
        switch filter {
        case .all:
            return "复制点什么，它就会出现在这里。"
        case .pinned:
            return "选中一条按 ⌘P 就能收藏，收藏的内容不会被自动清理。"
        case .queue:
            return "Hyper+Q 把选中的内容收进队列，Hyper+V 按顺序一条条粘贴出来。\n面板里选中一条按 ⌥↩ 也能加进来。"
        case .text:
            return "复制一段文字，它会自动归到这一页。"
        case .url:
            return "复制一个网址，它会被认出来，单独归到这一页。"
        case .image:
            // The one tab that can stay empty because of a setting rather than because
            // nothing was copied, so it says where to look.
            return "截图或复制一张图片就会出现在这里。\n如果一直是空的，看看设置里有没有关掉「记录图片」。"
        case .files:
            return "在访达里复制文件，路径会记在这里，之后还能从面板里拖出去。"
        }
    }

    /// Only where it is worth saying: on 全部 there is nowhere else to look, and the
    /// answer to an empty search there is simply another query.
    private var searchDetail: String? {
        guard filter != .all else { return nil }
        return "现在只在「\(filter.label)」里找。按 Tab 切到全部再试试。"
    }
}

/// One key and what it does, as the hint bar and the shortcut sheet both draw it.
///
/// Shared rather than redrawn per site because the sheet covers the list while the hint
/// bar stays visible underneath it: two takes on the same key cap would be side by side
/// on screen, reading as two different kinds of thing.
private struct KeyCap: View {
    let key: String
    let label: String
    /// Set where the caps have to line up into a column, as they do in the sheet's two
    /// columns; left nil the cap is as wide as its key, which is what a row of hints
    /// with different keys in it wants.
    var keyWidth: CGFloat?
    /// Set on the one cap in a row that is the obvious thing to do next. Everything else
    /// stays secondary, or nothing stands out.
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill((tint ?? .secondary).opacity(0.15))
                )
                .frame(width: keyWidth, alignment: .leading)
            Text(label)
                .font(.system(size: 10))
                // Wraps rather than truncates: the sheet's descriptions are the long
                // ones, and a column of them is narrow.
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint ?? .secondary)
    }
}

/// The hint bar's other face: what a multi-selection can be done with.
///
/// It replaces the hints rather than joining them because the hints are about the row
/// under the pointer, and with a selection in hand that is not what anything acts on any
/// more. Every button here is also a key, and says which — the bar is meant to teach
/// itself out of a job.
private struct BatchBar: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    var body: some View {
        HStack(spacing: 8) {
            Text("已选 \(model.checked.count) 条")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Spacer(minLength: 4)
            // ↩ over a multi-selection joins the rows either way; the setting decides
            // whether the result is sent or left on the clipboard, and the button has to
            // say which — a bar that advertised a key and then did something else with
            // the click would be worse than no bar.
            button(
                "↩", model.returnPastes ? "合并粘贴" : "合并复制", tint: .accentColor
            ) { actions.returnAction() }
            button("⌥↩", "加入队列") { actions.enqueue() }
            // ⌘⌫ means "take it out of the queue" on the queue tab and "delete it"
            // everywhere else — see the key itself in `handle(_:)`. The button says
            // whichever one the key would do, because a bar that advertised a key and
            // then did something else with the click would be worse than no bar.
            if model.filter == .queue {
                button("⌘⌫", "移出队列") { actions.dequeue() }
            } else {
                button("⌘⌫", "删除") { actions.delete() }
            }
            button("Esc", "取消") { model.clearChecked() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func button(
        _ key: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            KeyCap(key: key, label: label, tint: tint)
                // A row this tight would otherwise wrap the labels rather than let the
                // bar be as wide as it needs to be.
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)，\(key)")
    }
}

private struct HintBar: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    /// Kept to what fits the list's width on one line, and to what applies *now* — a bar
    /// that always said the same three things would be describing the panel rather than
    /// the situation. Everything it leaves out is one `?` away.
    ///
    /// Ordered most specific first, and one line's worth each — 「⌥点击 多选」 was dropped
    /// from the default set to make room for the preview, because a key that reveals a
    /// whole pane nobody had found is worth more than a second way to do what ⌘A and
    /// ⇧↑↓ already do. It is still in the sheet.
    private var hints: [(String, String)] {
        // Whatever ↩ is set to do. It leads every one of these sets, so getting it wrong
        // would be the panel's most visible lie.
        let returnLabel = model.returnPastes ? "粘贴" : "复制"
        if model.filter == .queue {
            return [("↩", returnLabel), ("⌘⌫", "移出队列"), ("⌘⇧K", "清空队列")]
        }
        if !model.query.isEmpty {
            return [("↩", returnLabel), ("Esc", "清空搜索")]
        }
        // Under 「仅复制」 the paste is the one thing the bar has to point at, because it
        // is the half that moved: ⌘↩ is now where it lives.
        let second = model.returnPastes ? ("→", "预览") : ("⌘↩", "粘贴")
        return [("↩", returnLabel), second, ("⌘点击", "连续粘贴")]
    }

    /// The `?` is only offered where it is also the key that works: with something typed
    /// in the field, `?` is a character rather than a shortcut.
    private var offersShortcuts: Bool { model.query.isEmpty }

    var body: some View {
        // A selection in hand is something the user is in the middle of, and what to do
        // with it displaces everything the bar would otherwise be saying.
        if !model.checked.isEmpty {
            BatchBar(model: model, actions: actions)
        } else {
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
}

/// Everything the panel answers to, over the list.
///
/// A sheet rather than a longer hint bar: the full set is two dozen entries, and the bar
/// has room for three. It covers the list because that is the only space a panel of
/// fixed size has to give — and because the list is exactly what you stop looking at
/// while you look one of these up.
private struct ShortcutsOverlay: View {
    /// The sheet is the panel's own account of itself, so the one key the settings can
    /// redefine has to be read from the settings rather than written down here.
    let returnPastes: Bool
    let dismiss: () -> Void

    private var entries: [(String, String)] {
        let first: [(String, String)] = returnPastes
            ? [("↩", "粘贴"), ("⌘↩", "以纯文本粘贴")]
            : [("↩", "复制并关闭"), ("⌘↩", "粘贴")]
        return first + Self.rest
    }

    private static let rest: [(String, String)] = [
        ("⌥↩", "加入队列"),
        ("⌘1-9", "粘贴第 n 条"),
        ("↑ ↓", "上下移动"),
        ("⇧↑ ⇧↓", "多选"),
        ("PgUp PgDn", "上下翻 10 行"),
        ("Home End", "跳到首行 / 末行"),
        ("→ ←", "展开 / 收起预览"),
        ("Tab", "切换过滤"),
        ("⌘A", "全选当前列表"),
        ("⌘P", "收藏 / 取消"),
        ("⌘C", "只复制，不粘贴"),
        ("⌘⌫", "删除（队列页：移出队列）"),
        ("⌘Z", "撤销刚才的删除"),
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
        let entries = self.entries
        let half = (entries.count + 1) / 2
        return (Array(entries.prefix(half)), Array(entries.dropFirst(half)))
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
                // Fixed width so the descriptions line up into a column of their own.
                // Wide enough for the longest cap in the list — "PgUp PgDn" — because a
                // cap that truncates its own key is worse than a column that is roomy.
                KeyCap(key: key, label: label, keyWidth: 66)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(key)，\(label)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
