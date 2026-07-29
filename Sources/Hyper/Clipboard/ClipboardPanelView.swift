import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(model: model, actions: actions)
            Divider().opacity(0.6)

            if model.results.isEmpty {
                EmptyResults(hasQuery: !model.query.isEmpty, filter: model.filter)
            } else {
                HStack(spacing: 0) {
                    ResultList(model: model, actions: actions)
                        .frame(width: 372)
                    Divider().opacity(0.6)
                    PreviewPane(model: model)
                        .frame(maxWidth: .infinity)
                }
            }

            Divider().opacity(0.6)
            HintBar(model: model)
        }
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
    }
}

private struct QueueBadge: View {
    let count: Int
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.append").font(.system(size: 10, weight: .bold))
            Text("队列 \(count)").font(.system(size: 11, weight: .semibold))
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("清空队列（⌘⇧K）")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
        .foregroundStyle(Color.accentColor)
    }
}

// MARK: - List

private struct ResultList: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, record in
                        ResultRow(
                            record: record,
                            index: index,
                            selected: index == model.selectedIndex,
                            checked: model.checked.contains(record.id),
                            queued: model.isQueued(record.id),
                            thumbnail: record.kind == .image ? model.thumbnail(for: record) : nil
                        )
                        .id(record.id)
                        .contentShape(Rectangle())
                        // ⌘-click ticks a row for a merged paste. Registered at high
                        // priority so it wins over the plain-click paste below.
                        .highPriorityGesture(
                            TapGesture().modifiers(.command).onEnded {
                                actions.selectIndex(index)
                                actions.toggleChecked(record.id)
                            }
                        )
                        .onTapGesture {
                            actions.selectIndex(index)
                            actions.paste(false)
                        }
                        .contextMenu {
                            Button("粘贴") { actions.selectIndex(index); actions.paste(false) }
                            Button("以纯文本粘贴") { actions.selectIndex(index); actions.paste(true) }
                            Button("只复制，不粘贴") { actions.selectIndex(index); actions.copyOnly() }
                            Divider()
                            Button("加入批量队列") { actions.selectIndex(index); actions.enqueue() }
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
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            .onChange(of: model.selectedIndex) { _ in
                guard let record = model.selected else { return }
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
    let thumbnail: NSImage?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.preview)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(record.subtitle())
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
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
    }

    private var background: Color {
        if selected { return .accentColor }
        if checked { return .accentColor.opacity(0.12) }
        if hovering { return .secondary.opacity(0.10) }
        return .clear
    }

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
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.13))
                .overlay(
                    Image(systemName: record.kind.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                )
        }
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
            if queued {
                Image(systemName: "text.append")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
            }
            if record.pinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white : Color.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
                    .opacity(selected || hovering ? 1 : 0.45)
            }
        }
    }
}

// MARK: - Preview pane

private struct PreviewPane: View {
    @ObservedObject var model: ClipboardPanelModel
    @State private var text: String?

    var body: some View {
        Group {
            if let record = model.selected {
                VStack(alignment: .leading, spacing: 0) {
                    content(for: record)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider().opacity(0.6)
                    metadata(for: record)
                }
                .task(id: record.id) {
                    text = record.kind == .image ? nil : model.fullText(for: record)
                }
            } else {
                Color.clear
            }
        }
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
        } else if let text, !text.isEmpty {
            ScrollView {
                Text(text)
                    .font(.system(size: 12.5, design: record.kind == .files ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
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

    private func metadata(for record: ClipRecord) -> some View {
        HStack(spacing: 10) {
            Label(record.kind.label, systemImage: record.kind.symbolName)
            if let name = record.sourceName, !name.isEmpty {
                Text("·")
                Text(name)
            }
            if record.byteSize > 0 {
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteSize), countStyle: .file))
            }
            Spacer()
            Text(record.createdAt, style: .time)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Empty / hints

private struct EmptyResults: View {
    let hasQuery: Bool
    let filter: PanelFilter

    var body: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: hasQuery ? "magnifyingglass" : "clipboard")
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

    private var title: String {
        filter == .pinned ? "还没有收藏任何内容" : "剪贴板历史是空的"
    }

    private var detail: String {
        filter == .pinned
            ? "选中一条按 ⌘P 就能收藏，收藏的内容不会被自动清理。"
            : "复制点什么，它就会出现在这里。"
    }
}

private struct HintBar: View {
    @ObservedObject var model: ClipboardPanelModel

    private var hints: [(String, String)] {
        var items: [(String, String)] = [("↩", model.checked.count > 1 ? "合并粘贴" : "粘贴")]
        items.append(("⌘↩", "纯文本"))
        items.append(("⌥↩", "入队"))
        items.append(("⌘点击", "多选"))
        items.append(("⌘P", "收藏"))
        items.append(("⌘⌫", "删除"))
        items.append(("⇥", "筛选"))
        return items
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(hints, id: \.0) { key, label in
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
            Spacer()
            Text("\(model.results.count) 条")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
