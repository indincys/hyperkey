import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a *row* will take a drop of: everything the list as a whole accepts, plus the
/// private marker every row of ours carries.
///
/// The marker is what makes the 收藏 reorder reachable. A row dragged on that tab carries
/// nothing any other process can read — that is the point, see
/// `ClipboardPanelController.reorderProvider` — and a target declared only over public
/// types might never be offered it, which would leave the band unrearrangeable. Declaring
/// the marker here says "this drag is for us" in the one vocabulary that cannot be missed.
/// It costs the other tabs nothing: a drag of our own is refused by `ClipDropTarget`
/// wherever it is not a reorder, exactly as before.
private let clipRowDropTypes: [UTType] =
    ClipDropIntake.acceptedTypes + [UTType(exportedAs: ClipDragItem.privateTypeIdentifier)]

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(model: model, actions: actions)
            PanelHairline()

            if let issue = model.pasteIssue {
                PasteIssueBanner(issue: issue, actions: actions)
                    .transition(
                        model.reduceMotion
                            ? .identity
                            : .opacity.combined(with: .move(edge: .top))
                    )
                PanelHairline()
            }

            // Takes whatever the header and the hint bar leave over, so the list
            // scrolls inside a panel of fixed height instead of setting it. The
            // shortcut sheet is laid over this middle band rather than the whole
            // window: the search field and the hint bar are what the sheet is
            // explaining, so covering them would be answering the question by hiding it.
            ZStack {
                if model.results.isEmpty && model.isSearchLoading {
                    SearchLoadingState()
                } else if model.results.isEmpty {
                    EmptyResults(hasQuery: !model.query.isEmpty, filter: model.filter)
                } else {
                    ResultList(model: model, actions: actions)
                }
                // One layer, two cards, and never both: the first appearance is the one
                // moment the panel gets to explain itself, and answering "what are the
                // keys" over the top of that would be two answers to one question.
                if model.showingOnboarding {
                    OnboardingOverlay(
                        reduceMotion: model.reduceMotion, dismiss: actions.dismissOnboarding
                    )
                } else if model.showingShortcuts {
                    ShortcutsOverlay(
                        returnPastes: model.returnPastes,
                        previewAvailable: model.previewAvailable
                    ) {
                        model.showingShortcuts = false
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // The whole middle band takes a drop, list and empty state alike — an empty
            // history is exactly where dragging something in has most to offer. Each row
            // carries the same target as well, because a drop lands on one target and the
            // rows cover nearly all of this: see `ClipDropTarget`.
            .overlay(DropHighlight(active: model.dropTargeted, reduceMotion: model.reduceMotion))
            .onDrop(
                of: ClipDropIntake.acceptedTypes,
                delegate: ClipDropTarget(index: nil, model: model, actions: actions)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The palette reaches every view below through the environment, and the two
        // defaults everything inherits are set here so no leaf has to remember them.
        .environment(\.panelTheme, model.theme)
        .foregroundStyle(model.theme.text)
        .tint(model.theme.accent)
        // The permanent hint bar is gone. It said the same three things under every list
        // and cost a whole strip of the panel to do it; what it was really for — telling
        // you an action landed — is what the toast does, at the moment it is true, and
        // only for the actions that leave the panel up to be told anything.
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                PanelToast(text: toast)
                    .padding(.bottom, 16)
                    .transition(
                        model.reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom))
                    )
            }
        }
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.18), value: model.toast)
    }
}

/// What just happened, at the foot of the list, for about a second.
private struct PanelToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color(white: 0.08, opacity: 0.85))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
            .accessibilityHidden(true)
    }
}

/// A persistent, actionable counterpart to the paste HUD. It is deliberately part of
/// the panel's layout rather than an alert: the failed rows stay visible underneath,
/// selection is not modal, and retry is one predictable tab stop away.
private struct PasteIssueBanner: View {
    let issue: ClipboardPasteIssue
    let actions: ClipboardPanelActions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(issue.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("粘贴错误。\(issue.title)。\(issue.detail)")

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    if issue.offersAccessibilitySettings {
                        Button("打开系统设置", action: actions.openAccessibilitySettings)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("打开隐私与安全性中的辅助功能设置")
                    }
                    if issue.offersSkipInvalid {
                        Button("跳过不可用项继续", action: actions.skipInvalidPaste)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("明确跳过错误中列出的条目，只处理其余可用内容")
                    }
                    Button("重新粘贴", action: actions.retryPaste)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint("保留当前选择并再次执行刚才的操作")
                }
                Button(action: actions.dismissPasteIssue) {
                    Label("关闭错误提示", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭粘贴错误提示")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
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

/// A real AppKit search control gives the panel a queryable AXTextField/AXSearchField
/// node even when SwiftUI's semantic tree is not exported by a hosting window. It also
/// owns the two menu shortcuts while its editor has focus, which is the common case.
final class PanelSearchTextField: NSSearchField {
    var openSyntax: (() -> Void)?
    var openSavedFilters: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.option),
              !flags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "f": openSyntax?(); return true
        case "s": openSavedFilters?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    /// The panel's palette. The field is an AppKit control on a sheet whose face is not
    /// necessarily the window's, so nothing about its colour can be left to the system.
    let theme: ClipPanelTheme
    let openSyntax: () -> Void
    let openSavedFilters: () -> Void

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PanelSearchField
        var appliedFocusRequest = -1
        /// The face the field's own colours were last set for.
        var appliedTheme: ClipPanelTheme?

        init(parent: PanelSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> PanelSearchTextField {
        let field = PanelSearchTextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 14)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.sendsSearchStringImmediately = true
        // The header draws the magnifier itself, at the size and colour everything else
        // in the row is drawn at. `NSSearchField` insists on its own as well, and the two
        // landed on top of each other — the doubled glyph behind the placeholder was
        // exactly this. The cancel button goes for the same reason: Escape already clears
        // the field, and the row has no width to spare for a second way to do it.
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.setAccessibilityRole(.textField)
        field.setAccessibilitySubrole(.searchField)
        field.setAccessibilityLabel(PanelSearchAccessibility.fieldLabel)
        field.setAccessibilityHelp(PanelSearchAccessibility.fieldHint)
        field.setAccessibilityIdentifier("clipboard-search-field")
        return field
    }

    func updateNSView(_ field: PanelSearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        // Only when the face actually changed. `updateNSView` runs on every pass the
        // panel makes — which is every row the pointer crosses — and `NSColor(Color)`
        // plus a fresh `NSAttributedString` on each of those is real, measurable work
        // for a placeholder that changes about twice in a session.
        if context.coordinator.appliedTheme != theme {
            context.coordinator.appliedTheme = theme
            field.textColor = NSColor(theme.text)
            // Set through the attributed placeholder because `placeholderString` takes
            // the system's own tertiary colour, which is keyed to the window's
            // appearance rather than to the panel's.
            field.placeholderAttributedString = NSAttributedString(
                string: PanelSearchAccessibility.fieldLabel,
                attributes: [
                    .foregroundColor: NSColor(theme.text3),
                    .font: NSFont.systemFont(ofSize: 14),
                ]
            )
        }
        field.openSyntax = openSyntax
        field.openSavedFilters = openSavedFilters
        guard context.coordinator.appliedFocusRequest != focusRequest else { return }
        context.coordinator.appliedFocusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            let editor = field.currentEditor() as? NSTextView
            guard PanelSearchFocus.shouldTakeFocus(
                windowIsVisible: window.isVisible,
                alreadyEditing: window.firstResponder === editor && editor != nil,
                composing: editor?.hasMarkedText() ?? false
            ) else { return }
            window.makeFirstResponder(field)
        }
    }
}

/// Whether a focus request should actually be acted on.
///
/// `makeFirstResponder` on a field that is *already* being typed into is not a no-op:
/// AppKit tears the field editor down and installs a fresh one, and an input method's
/// marked text goes with it — half a word of pinyin simply vanishes. Two of the three
/// things that ask for focus are not user actions at all (the keyboard being handed back
/// half a second after a 连续粘贴, and a failed paste restoring the panel), so either
/// could land in the middle of someone typing.
///
/// A pure function because the interesting cases are exactly the ones that are miserable
/// to stage: a window that is not on screen yet, and a field editor with marked text in
/// it.
enum PanelSearchFocus {
    static func shouldTakeFocus(
        windowIsVisible: Bool, alreadyEditing: Bool, composing: Bool
    ) -> Bool {
        // Prewarming builds the panel while it is off screen. Nothing should be taking
        // the keyboard there — least of all from whatever the user is really working in.
        guard windowIsVisible else { return false }
        // Mid-composition the field editor must not be replaced, and there is nothing to
        // do anyway: it already has the keyboard.
        guard !composing else { return false }
        return !alreadyEditing
    }
}

/// Native, individually queryable confirmation controls. Return/Escape are also routed
/// through the panel's local key monitor; Space and VoiceOver press work directly here.
final class PanelDeleteConfirmationBar: NSView {
    private let titleField = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    let deleteButton = NSButton(title: "删除筛选", target: nil, action: nil)
    var cancel: (() -> Void)?
    var confirm: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("删除已保存筛选确认")
        setAccessibilityHelp("确认只删除筛选，不删除剪贴板历史")

        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityRole(.button)
        cancelButton.setAccessibilityLabel("取消删除筛选")
        cancelButton.setAccessibilityHelp("保留这个已保存筛选")
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)
        deleteButton.keyEquivalent = "\r"
        deleteButton.bezelColor = .systemRed
        deleteButton.setAccessibilityRole(.button)
        deleteButton.setAccessibilityLabel("确认删除筛选")
        deleteButton.setAccessibilityHelp("删除筛选，不删除剪贴板历史")

        let stack = NSStackView(views: [titleField, cancelButton, deleteButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(name: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        titleField.stringValue = "删除“\(name)”？"
        self.cancel = cancel
        self.confirm = confirm
    }

    @objc private func cancelPressed() { cancel?() }
    @objc private func deletePressed() { confirm?() }
}

private struct PanelDeleteConfirmation: NSViewRepresentable {
    let filter: SmartFilter
    let cancel: () -> Void
    let confirm: () -> Void

    func makeNSView(context: Context) -> PanelDeleteConfirmationBar {
        PanelDeleteConfirmationBar()
    }

    func updateNSView(_ view: PanelDeleteConfirmationBar, context: Context) {
        view.configure(name: filter.name, cancel: cancel, confirm: confirm)
    }
}

private struct SearchHeader: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions
    @Environment(\.panelTheme) private var theme
    @State private var focusRequest = 0

    /// What the pill row's width is spent on besides pills: 12pt of padding a side, and
    /// a little kept back so the badges after the spacer are not squeezed to nothing the
    /// moment the counts reach four digits.
    private static let pillRowReserve: CGFloat = 24 + 18
    @State private var filterEditor: FilterEditor?
    @State private var filterName = ""

    private enum FilterEditor: Identifiable {
        case create
        case rename(SmartFilter)

        var id: String {
            switch self {
            case .create: return "create"
            case .rename(let filter): return "rename-\(filter.id.uuidString)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // One row, where there were two. The two menus that used to sit on a line of
            // their own — with a label each, and a whole 24pt band to themselves — are the
            // three glyph buttons at the end of this one: they are things reached for
            // rarely and by name, so a word each was paying list height for a label
            // nobody reads twice.
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text3)
                    .accessibilityHidden(true)

                PanelSearchField(
                    text: $model.query,
                    focusRequest: focusRequest,
                    theme: theme,
                    openSyntax: insertSuggestedToken,
                    openSavedFilters: beginSavingCurrentFilter
                )
                .frame(minHeight: 22)

                if model.isSearchLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .frame(width: 14)
                        .accessibilityLabel("正在更新搜索结果")
                }

                if !model.checked.isEmpty {
                    SelectionBadge(
                        count: model.checked.count, returnPastes: model.returnPastes
                    )
                } else if let name = model.targetAppName {
                    // On this row rather than beside the pills. Tried there first, and it
                    // was measurably wrong: the badge claimed its ideal width before
                    // `FilterPills` was offered anything, none of that row's four
                    // densities then fitted, and the panel shipped a tab bar reading
                    // 「… … … 文本 链接」. Here it is the piece that gives way instead — see
                    // the priority it carries.
                    PasteTargetBadge(name: name, icon: model.targetAppIcon)
                }

                // Values, not the model, and `.equatable()` behind them — the same
                // prescription `FilterPills` is on. Between them these four controls are
                // two `Menu`s whose contents are a `ForEach` each, and they were being
                // rebuilt for every row the pointer crossed: the suggestion list, every
                // saved filter and its three-button submenu, the labels, the shortcuts.
                // None of it can change while a pointer is moving.
                HeaderControls(
                    dark: theme.dark,
                    theme: theme,
                    suggestions: model.querySuggestions,
                    savedFilters: model.smartFilters,
                    filtersReady: model.areSmartFiltersReady,
                    canSaveCurrentQuery: canSaveCurrentQuery,
                    toggleAppearance: model.toggleAppearance,
                    insertSuggestion: { suggestion in
                        model.insertQuerySuggestion(suggestion)
                        focusRequest &+= 1
                    },
                    beginSaving: {
                        filterName = suggestedFilterName
                        filterEditor = .create
                    },
                    applyFilter: { _ = model.applySmartFilter($0) },
                    beginRenaming: { filter in
                        filterName = filter.name
                        filterEditor = .rename(filter)
                    },
                    requestDeletion: { model.requestSmartFilterDeletion($0) },
                    toggleShortcuts: actions.toggleShortcuts
                )
                .equatable()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if let issue = model.queryIssue {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(issue.localizedDescription)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(PanelSearchAccessibility.queryError(issue))
            }

            if let issue = model.smartFilterIssue {
                HStack(spacing: 6) {
                    Text(issue)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                    Button("关闭") { model.dismissSmartFilterIssue() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .accessibilityLabel("关闭已保存筛选错误")
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .accessibilityElement(children: .contain)
            }

            if let pending = model.pendingSmartFilterDeletion {
                PanelDeleteConfirmation(
                    filter: pending,
                    cancel: model.cancelSmartFilterDeletion,
                    confirm: { _ = model.confirmSmartFilterDeletion() }
                )
                .frame(height: 28)
                .padding(.horizontal, 14)
                .padding(.top, 7)
            }

            HStack(spacing: 6) {
                // Values, not the model, and `.equatable()` behind them: see `FilterPills`.
                FilterPills(
                    selected: model.filter,
                    counts: model.filterCounts,
                    available: model.panelWidth - Self.pillRowReserve,
                    theme: theme,
                    onSelect: { model.filter = $0 }
                )
                .equatable()
                Spacer(minLength: 4)
                // Everything after the spacer yields to the pills — a tab whose label is
                // cut in half has stopped being a tab, and these are both things you
                // read once and then stop looking at.
                if let name = model.activeSmartFilterName {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.text3)
                        .layoutPriority(-1)
                        .accessibilityLabel("当前已保存筛选：\(name)")
                }
                if model.queueCount > 0 {
                    QueueBadge(count: model.queueCount, onClear: actions.clearQueue)
                        .layoutPriority(-1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 11)
        }
        // The window is built once and reused for every appearance, so `onAppear` runs
        // exactly once in a session — which is why the second and every later opening
        // could land with the keyboard somewhere else entirely. The model asks for focus
        // per *appearance* now; this is still here for the very first one, where the
        // model's tick has already been bumped before this view existed.
        .onAppear { focusRequest &+= 1 }
        .onChange(of: model.searchFocusTick) { _ in focusRequest &+= 1 }
        .alert(editorTitle, isPresented: editorPresented) {
            TextField("筛选名称", text: $filterName)
                .accessibilityLabel("已保存筛选名称")
            Button("取消", role: .cancel) { filterEditor = nil }
            Button(editorActionTitle) { submitFilterEditor() }
                .disabled(filterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("保存后可从面板直接应用；查询内容会加密存储。")
        }
    }

    /// Whether 「保存当前查询…」 is offered: something typed, no syntax error, and the
    /// saved-filter library actually loaded.
    private var canSaveCurrentQuery: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.queryIssue == nil && model.areSmartFiltersReady
    }

    private var editorTitle: String {
        switch filterEditor {
        case .create, .none: return "保存当前查询"
        case .rename: return "重命名已保存筛选"
        }
    }

    private var editorActionTitle: String {
        if case .rename = filterEditor { return "重命名" }
        return "保存"
    }

    private var editorPresented: Binding<Bool> {
        Binding(
            get: { filterEditor != nil },
            set: { if !$0 { filterEditor = nil } }
        )
    }

    private var suggestedFilterName: String {
        let compact = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count <= 24 ? compact : String(compact.prefix(24)) + "…"
    }

    private func submitFilterEditor() {
        switch filterEditor {
        case .create:
            _ = model.saveCurrentSmartFilter(named: filterName)
        case .rename(let filter):
            _ = model.renameSmartFilter(filter.id, to: filterName)
        case .none:
            break
        }
        filterEditor = nil
        focusRequest &+= 1
    }

    private func insertSuggestedToken() {
        guard let suggestion = model.querySuggestions.first else { return }
        model.insertQuerySuggestion(suggestion)
        focusRequest &+= 1
    }

    private func beginSavingCurrentFilter() {
        guard canSaveCurrentQuery else {
            NSSound.beep()
            focusRequest &+= 1
            return
        }
        filterName = suggestedFilterName
        filterEditor = .create
    }
}

/// The four glyph buttons at the end of the search row: the face toggle, the query-syntax
/// menu, the saved-filter menu, and `?`.
///
/// Values and closures rather than the model, and `Equatable` behind them. The header as
/// a whole observes the model — it has to, it draws the query, the counts and the badges
/// — and observing means every change the panel publishes re-evaluates all of it. That
/// includes two `Menu`s: one `ForEach` over the query suggestions, another over every
/// saved filter with a three-button submenu inside each. The pointer crossing a row
/// changes none of that, and there are twenty rows in a panel.
///
/// The two closures that open the rename/save sheet are deliberately callbacks rather
/// than the sheet itself: the search field's own ⌘⌥F and ⌘⌥S reach the same two actions,
/// so the state they drive belongs one level up, with them.
private struct HeaderControls: View, Equatable {
    let dark: Bool
    let theme: ClipPanelTheme
    let suggestions: [PanelQuerySuggestion]
    let savedFilters: [SmartFilter]
    let filtersReady: Bool
    let canSaveCurrentQuery: Bool
    let toggleAppearance: () -> Void
    let insertSuggestion: (PanelQuerySuggestion) -> Void
    let beginSaving: () -> Void
    let applyFilter: (UUID) -> Void
    let beginRenaming: (SmartFilter) -> Void
    let requestDeletion: (SmartFilter) -> Void
    let toggleShortcuts: () -> Void

    /// The closures are not compared — closures cannot be, and every one of them is
    /// rebuilt identical on each pass. Everything these controls *draw* is above them.
    static func == (lhs: HeaderControls, rhs: HeaderControls) -> Bool {
        lhs.dark == rhs.dark && lhs.theme == rhs.theme
            && lhs.suggestions == rhs.suggestions
            && lhs.savedFilters == rhs.savedFilters
            && lhs.filtersReady == rhs.filtersReady
            && lhs.canSaveCurrentQuery == rhs.canSaveCurrentQuery
    }

    var body: some View {
        Group {
            PanelIconButton(
                symbol: dark ? "moon.fill" : "sun.max.fill",
                label: "切换外观",
                hint: "在深色和浅色之间切换面板外观",
                action: toggleAppearance
            )
            querySyntaxMenu
            smartFilterMenu
            PanelIconButton(
                symbol: "questionmark",
                label: "快捷键速查",
                hint: "查看全部快捷键（?）",
                action: toggleShortcuts
            )
        }
    }

    private var querySyntaxMenu: some View {
        Menu {
            Section("查询示例") {
                ForEach(suggestions) { suggestion in
                    Button {
                        insertSuggestion(suggestion)
                    } label: {
                        Text("\(suggestion.title)：\(suggestion.token)")
                    }
                    .help(suggestion.detail)
                }
            }
            Divider()
            Text("空格表示同时满足 · 前缀 - 表示排除")
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .panelIconChip(theme)
        .keyboardShortcut("f", modifiers: [.command, .option])
        .help("查看并插入 app、type、日期、收藏和队列筛选")
        .accessibilityLabel(PanelSearchAccessibility.syntaxMenuLabel)
        .accessibilityHint(PanelSearchAccessibility.syntaxMenuHint)
    }

    private var smartFilterMenu: some View {
        Menu {
            Button(action: beginSaving) {
                Label("保存当前查询…", systemImage: "plus")
            }
            .disabled(!canSaveCurrentQuery)

            if !savedFilters.isEmpty { Divider() }
            ForEach(savedFilters) { filter in
                Menu(filter.name) {
                    Button("应用") { applyFilter(filter.id) }
                    Button("重命名…") { beginRenaming(filter) }
                    Divider()
                    Button("删除…", role: .destructive) { requestDeletion(filter) }
                }
            }
        } label: {
            Image(systemName: savedFilters.isEmpty ? "bookmark" : "bookmark.fill")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .panelIconChip(theme)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .help("保存、应用、重命名或删除高级查询")
        .accessibilityLabel(
            filtersReady
                ? PanelSearchAccessibility.savedFilters(count: savedFilters.count)
                : "正在加载已保存筛选"
        )
        .accessibilityHint("打开菜单管理已加密保存的查询")
    }
}

/// A hairline in the panel's own palette. `Divider` takes the *window's* appearance,
/// which is not necessarily the panel's — a dark sheet over a light desktop got a dark
/// line on dark glass, which is no line at all.
private struct PanelHairline: View {
    @Environment(\.panelTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The 22pt square the header's four controls are all drawn in.
///
/// A modifier rather than a wrapper view, because two of the four are `Menu`s and a menu
/// cannot be handed a label from outside itself.
private struct PanelIconChip: ViewModifier {
    let theme: ClipPanelTheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.text2)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.chip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(theme.chipBorder, lineWidth: theme.borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension View {
    fileprivate func panelIconChip(_ theme: ClipPanelTheme) -> some View {
        modifier(PanelIconChip(theme: theme))
    }
}

private struct PanelIconButton: View {
    let symbol: String
    let label: String
    let hint: String
    let action: () -> Void

    @Environment(\.panelTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .panelIconChip(theme)
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(label)
    }
}

/// What a multi-selection is, and what ↩ will do with it.
///
/// This is where the batch bar went. A whole strip at the foot of the panel to say "已选
/// 3 条" was the list paying for a sentence; every button on it was a key, and the keys
/// still work — they are on the shortcut sheet, which is one glyph away. What is left is
/// the part that genuinely had to be visible: how many, and what happens next.
private struct SelectionBadge: View {
    let count: Int
    let returnPastes: Bool

    @Environment(\.panelTheme) private var theme

    var body: some View {
        Text("已选 \(count) · ↩ \(returnPastes ? "合并粘贴" : "合并复制")")
            .font(.system(size: 10))
            .foregroundStyle(theme.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.accent.opacity(0.14)))
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
            .accessibilityLabel(
                "已选中 \(count) 条，按回车\(returnPastes ? "合并粘贴" : "合并复制")，按 Esc 取消"
            )
    }
}

private struct SearchLoadingState: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("正在准备剪贴板历史…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PanelSearchAccessibility.loadingLabel)
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
///
/// It takes values rather than the model, and is `Equatable`, because `ViewThatFits` is
/// the most expensive thing in the header: it lays out all four candidate rows — 28 pills
/// — to find the first that fits. Observing the model meant redoing that on every change
/// the model publishes, which includes each row the pointer crosses on its way down the
/// list. The two values below are the whole of what the row draws from, so anything else
/// moving now leaves it alone.
/// How wide the seven pills want to be, and which density therefore fits.
///
/// Pure arithmetic over cached text measurements, and deliberately not a view: this
/// replaced a `ViewThatFits` over four candidate rows, which is the obvious way to write
/// it and was — measured, with the panel hosted and the pointer swept down the list —
/// **eighty-five percent of the cost of the whole panel**: 10.6ms for every row the
/// pointer crossed, against 1.5ms with the header taken out altogether.
///
/// `.equatable()` on the row did not help, and the reason is worth writing down:
/// it stops the *body* being re-evaluated, and `ViewThatFits` re-measures its candidates
/// during **layout**, which happens on every pass the panel makes. Twenty-eight pills
/// laid out and thrown away per row crossed is what "有点拖影" was.
///
/// Measuring the strings is also more honest than asking whether a laid-out row happened
/// to fit: the answer is the same, it is a few dictionary lookups, and it can be tested
/// without rendering anything.
enum PanelPillLayout {
    struct Density: Equatable {
        /// The size the count is drawn at, or nothing where the row had to give it up.
        let countSize: CGFloat?
        let hpad: CGFloat
        let spacing: CGFloat
    }

    /// Loosest first. The counts thin out and finally go, but a label is never cut.
    static let densities = [
        Density(countSize: 9.5, hpad: 9, spacing: 4),
        Density(countSize: 9.5, hpad: 7, spacing: 3),
        // A smaller number is still a number; this is the last rung that keeps them.
        Density(countSize: 9, hpad: 6, spacing: 2),
        Density(countSize: nil, hpad: 8, spacing: 4),
    ]

    static func pillWidth(
        _ filter: PanelFilter, count: Int, selected: Bool, density: Density
    ) -> CGFloat {
        var width = PanelTextWidth.width(
            filter.label, size: 11, weight: selected ? .semibold : .regular
        )
        if let countSize = density.countSize, count > 0 {
            width += 3 + PanelTextWidth.width("\(count)", size: countSize, weight: .regular)
        }
        return width + density.hpad * 2
    }

    static func rowWidth(
        counts: [PanelFilter: Int], selected: PanelFilter, density: Density
    ) -> CGFloat {
        var total = density.spacing * CGFloat(PanelFilter.allCases.count - 1)
        for filter in PanelFilter.allCases {
            total += pillWidth(
                filter, count: counts[filter] ?? 0, selected: selected == filter,
                density: density
            )
        }
        return total
    }

    /// The first density that fits, or the tightest one where none does — which is what
    /// the row had to do before as well, and is why the labels have `lineLimit(1)`.
    static func fitted(
        available: CGFloat, counts: [PanelFilter: Int], selected: PanelFilter
    ) -> Density {
        densities.first {
            rowWidth(counts: counts, selected: selected, density: $0) <= available
        } ?? densities[densities.count - 1]
    }
}

private struct FilterPills: View, Equatable {
    let selected: PanelFilter
    let counts: [PanelFilter: Int]
    /// How much room the row has for pills, in points. Passed in rather than discovered
    /// — see `PanelPillLayout`.
    let available: CGFloat
    let theme: ClipPanelTheme
    let onSelect: (PanelFilter) -> Void

    /// The closure is deliberately not compared — closures cannot be, and this one is
    /// rebuilt identical on every pass anyway. Everything the row *draws* is above it.
    static func == (lhs: FilterPills, rhs: FilterPills) -> Bool {
        lhs.selected == rhs.selected && lhs.counts == rhs.counts
            && lhs.available == rhs.available && lhs.theme == rhs.theme
    }

    var body: some View {
        let density = PanelPillLayout.fitted(
            available: available, counts: counts, selected: selected
        )
        HStack(spacing: density.spacing) {
            ForEach(PanelFilter.allCases) { filter in
                FilterPill(
                    filter: filter,
                    selected: selected == filter,
                    count: counts[filter] ?? 0,
                    countSize: density.countSize,
                    // Handed the width that was just computed for it, rather than
                    // letting the layout negotiate one: the arithmetic above already
                    // knows the answer, and asking seven pills to measure their own text
                    // again is that same work a second time.
                    width: PanelPillLayout.pillWidth(
                        filter, count: counts[filter] ?? 0,
                        selected: selected == filter, density: density
                    ),
                    theme: theme
                ) {
                    onSelect(filter)
                }
            }
        }
    }
}

/// Cached text widths, for the places that have to know how wide a string will be
/// before laying it out.
///
/// Main-thread only — every caller is a SwiftUI `body` — and the key space is tiny and
/// closed: seven fixed labels and a few hundred possible counts.
enum PanelTextWidth {
    private struct Key: Hashable {
        let text: String
        let size: CGFloat
        let weight: CGFloat
    }

    nonisolated(unsafe) private static var cache: [Key: CGFloat] = [:]

    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let key = Key(text: text, size: size, weight: weight.rawValue)
        if let hit = cache[key] { return hit }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (text as NSString)
            .size(withAttributes: [.font: font])
            .width
            .rounded(.up)
        // A closed key space, but a bounded cache regardless: nothing here is worth an
        // unbounded dictionary if a caller ever starts measuring arbitrary strings.
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = measured
        return measured
    }
}

/// Selected is a filled pill, unselected is an outline — the reverse of what the panel
/// used to do, where every pill was filled and the selection was the one in the accent
/// colour. Seven filled capsules is seven things asking to be looked at; six outlines
/// and one solid is one.
private struct FilterPill: View {
    let filter: PanelFilter
    let selected: Bool
    let count: Int
    /// The size the number is drawn at, or nothing where the row had to give it up.
    let countSize: CGFloat?
    let width: CGFloat
    let theme: ClipPanelTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(filter.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                // A row of zeros would be seven pieces of furniture saying nothing, so a
                // tab with nothing in it just wears its name.
                if let countSize, count > 0 {
                    Text("\(count)")
                        .font(.system(size: countSize))
                        .opacity(0.55)
                }
            }
            .lineLimit(1)
            .frame(width: width)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(selected ? theme.pillOn : .clear))
            .overlay(
                Capsule().strokeBorder(
                    selected ? .clear : theme.chipBorder, lineWidth: theme.borderWidth
                )
            )
            .foregroundStyle(selected ? theme.pillOnText : theme.text2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Spelled out, because "文本 260" on its own does not say 260 of what — and which
        // pill is switched on, which the fill alone conveys to everyone else. Spoken
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

    @Environment(\.panelTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(theme.text3)
        // A capped budget rather than an open claim. The search field is an AppKit
        // control and takes every point it is offered, so a badge that merely yielded to
        // it was left with nothing but its arrow; and the name is the half that answers
        // the question. Past 100pt it truncates instead, which the icon covers for.
        .frame(maxWidth: 100, alignment: .trailing)
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("回车将粘贴到 \(name)")
    }
}

/// How many entries the batch queue is holding, and a way to empty it.
private struct QueueBadge: View {
    let count: Int
    let onClear: () -> Void

    @Environment(\.panelTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "text.append")
                .font(.system(size: 8, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("清空队列（⌘⇧K）")
            .accessibilityLabel("清空队列")
        }
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.accent.opacity(0.14)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("批量队列，\(count) 条")
    }
}

private struct ClipDropTarget: DropDelegate {
    /// The row this is attached to, or nil for the list as a whole. A reorder needs a
    /// place to move the row *to*, which is the one thing the container cannot offer.
    let index: Int?
    let model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    private var reordering: Bool {
        index != nil && model.canReorderPinned && model.draggingID != nil
    }

    /// Whether what is in flight left this panel. Two accounts of the same thing: the row
    /// the list handed over, which is authoritative and costs nothing to read, and the
    /// private type every provider it builds carries — see `ClipDragItem`.
    ///
    /// The second is read from the model rather than from the `DropInfo`, because
    /// `itemProviders(for:)` rebuilds a provider list off the pasteboard every time it is
    /// asked and `dropUpdated` asks on every pointer move. It is worked out once per
    /// crossing instead, in `dropEntered`, and cleared on the way out.
    private func isOwn(_ info: DropInfo) -> Bool {
        model.draggingID != nil || model.dragIsOwn
    }

    func validateDrop(info: DropInfo) -> Bool {
        if reordering { return true }
        guard !isOwn(info) else { return false }
        return !info.itemProviders(for: ClipDropIntake.acceptedTypes).isEmpty
    }

    func dropEntered(info: DropInfo) {
        // A row the list itself handed over is authoritative and free to read. Asking
        // the pasteboard as well — which is what `isOwnDrag` does, item provider by item
        // provider — is real work, and it was being done again for every row a drag of
        // our own crossed on its way down the panel.
        model.noteDragIsOwn(model.draggingID != nil || ClipDropIntake.isOwnDrag(info))
        guard !reordering else {
            if let index { actions.movePinnedRow(index) }
            return
        }
        guard !isOwn(info) else { return }
        model.dropTargetEntered()
    }

    func dropExited(info: DropInfo) {
        guard !reordering else { return }
        model.dropTargetExited()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if reordering { return DropProposal(operation: .move) }
        return DropProposal(operation: isOwn(info) ? .cancel : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let own = isOwn(info)
        model.dropTargetFinished()
        // Nothing left to do: `dropEntered` has been moving the row the whole way across
        // and every rank in the band was written with it.
        guard !reordering else {
            model.noteDropCompleted()
            return true
        }
        guard !own else { return false }
        // `DropInfo.itemProviders(for:)` is a filtered view and can omit a second item
        // whose only representation is unknown. Use the live pasteboard synchronously
        // to prove that the filtered providers still cover every item, then retain only
        // DropInfo's native providers for asynchronous reads. Pasteboard item proxies can
        // become invalid immediately after this method returns.
        let providers = info.itemProviders(for: ClipDropIntake.acceptedTypes)
        guard ClipDropIntake.preflightCompleteSession(
            pasteboard: NSPasteboard(name: .drag), nativeProviders: providers
        ) else { return false }
        // Recorded because a drop is the one proof that a resign the panel decided to sit
        // through was really a drag heading here — see `endDragExemption`.
        model.noteDropCompleted()
        actions.saveDropped(providers)
        return true
    }
}

/// The border the list wears while something from elsewhere is held over it.
///
/// Drawn as an overlay rather than a background so it costs the list no room, and never
/// takes a click — it is the one thing on screen during a drag that must not be a target.
private struct DropHighlight: View {
    let active: Bool
    let reduceMotion: Bool

    @Environment(\.panelTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accent.opacity(0.07))
                )
            Text("松开即存入历史")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.dark ? Color(white: 0.07) : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.accent))
                .padding(.bottom, 14)
        }
        .padding(4)
        .opacity(active ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        .allowsHitTesting(false)
    }
}

// MARK: - Grouping

/// The band label above the row that opens it. Which rows those are is decided by the
/// model — see `ClipboardPanelModel.groupHeaders`.
private struct GroupHeader: View {
    let title: String
    let first: Bool

    @Environment(\.panelTheme) private var theme

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, first ? 2 : 13)
            .padding(.bottom, 5)
            // So VoiceOver's rotor can jump band to band rather than row by row.
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - List

private struct ResultList: View {
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    @Environment(\.panelTheme) private var theme

    /// The blocks, each carrying the identity of the row it opens.
    ///
    /// A block's place in the array is not an identity — inserting one entry at the top
    /// renumbers every block below it — so transitions and `scrollTo` are keyed to the
    /// record that opens it, which is stable across every rebuild that did not remove it.
    ///
    /// Read from one value, so the arrangement and the rows it indexes into cannot
    /// disagree — see `ClipboardPanelModel.PanelList`. Clamped as well, because the
    /// consequence of them disagreeing is not a wrong pixel but an index out of range,
    /// and that is worth two defences rather than one.
    private var laidOut: [(block: ClipPanelBlock, id: UUID)] {
        let list = model.list
        return list.blocks.compactMap { block in
            guard list.records.indices.contains(block.start) else { return nil }
            guard let clamped = clamp(block, to: list.records.count) else { return nil }
            return (clamped, list.records[block.start].id)
        }
    }

    private func clamp(_ block: ClipPanelBlock, to count: Int) -> ClipPanelBlock? {
        switch block {
        case .row(let index):
            return index < count ? block : nil
        case .grid(let range):
            let end = min(range.upperBound, count)
            guard end > range.lowerBound else { return nil }
            return end == range.upperBound ? block : .grid(range.lowerBound..<end)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(laidOut, id: \.id) { entry in
                        // The header rides along with the block it opens rather than
                        // being an element of its own, so the enumeration the rest of the
                        // panel indexes into stays one entry per record.
                        VStack(alignment: .leading, spacing: 3) {
                            if let title = model.groupHeaders[entry.block.start] {
                                GroupHeader(title: title, first: entry.block.start == 0)
                            }
                            switch entry.block {
                            case .row(let index):
                                row(at: index)
                            case .grid(let range):
                                ImageGridBlock(
                                    range: range, model: model, actions: actions
                                )
                            }
                        }
                        .id(entry.id)
                        // Blocks arrive and leave for reasons the list cannot show any
                        // other way — a deletion, an undo, a copy made in another
                        // application while the panel is up. Sliding in from above says
                        // where a new entry went; fading out says the row under the
                        // pointer is the one that just went. Only ever animated from
                        // `apply`, so blocks the lazy stack materialises while scrolling
                        // are not transitioned in as though they were new.
                        .transition(
                            model.reduceMotion
                                ? .identity
                                : .opacity.combined(with: .move(edge: .top))
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                // The space every contact sheet reports its frame in, and the space a
                // rubber band is resolved in. Inside the scrolled content rather than on
                // the `ScrollView`, so scrolling moves the sheets and the band together
                // and a band started before a scroll still means what it meant.
                .coordinateSpace(name: ClipListSpace.name)
            }
            // Keyed to `scrollTick`, not to the selection itself: the pointer moves the
            // selection too, and scrolling for that would slide the hovered row out
            // from under the pointer, hover whichever row replaced it, and scroll again.
            .onChange(of: model.scrollTick) { _ in
                guard let target = scrollTarget() else { return }
                let anchor = scrollAnchor()
                guard !model.reduceMotion else {
                    proxy.scrollTo(target, anchor: anchor)
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(target, anchor: anchor)
                }
            }
        }
    }

    /// Where in the window the selected row is put, or nowhere in particular.
    ///
    /// It was always `.center`, which meant every single ↑ and ↓ dragged the whole list
    /// past the eye by one row: nothing on screen ever stood still, and the row being
    /// read was permanently in motion under it. A step now asks for no anchor at all,
    /// which is `scrollTo`'s "make it visible": a row already on screen moves the list
    /// by nothing, and the list only follows once the selection reaches an edge of it.
    private func scrollAnchor() -> UnitPoint? {
        // Nil is the whole point of this, and it is not "no scrolling": `scrollTo` with
        // no anchor scrolls by the least it can to bring the row into view, and by
        // nothing at all when the row is already in view. A non-nil anchor is an
        // unconditional alignment — `.bottom` would pin the selected row to the bottom
        // edge on every ↓, which is the same permanent motion as `.center` was, just at
        // a different edge. A jump that is not a step still asks for the middle, where a
        // row arriving from nowhere can be read.
        model.scrollAnchorDirection == 0 ? .center : nil
    }

    /// What `scrollTo` can actually reach. A thumbnail inside a contact sheet is not a
    /// scroll target of its own — the sheet is — so a selection inside one scrolls to
    /// whichever record opens it.
    private func scrollTarget() -> UUID? {
        guard let selected = model.selected else { return nil }
        guard let block = ClipPanelLayout.block(
            containing: model.selectedIndex, in: model.blocks
        ), model.results.indices.contains(block.start) else { return selected.id }
        return model.results[block.start].id
    }

    @ViewBuilder
    private func row(at index: Int) -> some View {
        if let record = model.results.indices.contains(index) ? model.results[index] : nil {
            rowBody(record, at: index)
        }
    }

    @ViewBuilder
    private func rowBody(_ record: ClipRecord, at index: Int) -> some View {
        ResultRow(
            record: record,
            index: index,
            selected: index == model.selectedIndex,
            checked: model.checked.contains(record.id),
            queued: model.isQueued(record.id),
            queuePosition: model.queuePosition(at: index),
            visualState: model.visualState(for: record),
            terms: model.highlightTerms,
            context: model.contexts[record.id],
            matchNote: model.visibleMatchExplanation(for: record.id),
            // Worked out once per published list rather than per row per frame — see
            // `RowPresentation`.
            presentation: model.presentation(for: record),
            // A value rather than the environment, because `.equatable()` below is a
            // promise that everything the row draws from is in these properties.
            theme: theme,
            reduceMotion: model.reduceMotion,
            onPin: { actions.togglePinRow(index) },
            onDelete: { actions.deleteRow(index) },
            onDequeue: { actions.dequeueRow(index) }
        )
        // The list is rebuilt whenever anything at all in the panel changes — a
        // thumbnail landing, a tab count, the pointer crossing one row twenty rows away.
        // This is what stops each of those from re-deriving every visible row: the row
        // compares equal, and its body is not run.
        .equatable()
        .modifier(ClipRowBehaviour(model: model, actions: actions, record: record, index: index))
    }
}

/// Whether two thumbnail states would draw the same thing.
///
/// `ClipVisualState` cannot be `Equatable`: a decoded asset holds an `NSImage`, and
/// comparing two of those means comparing pixels. What a row actually needs to know is
/// narrower — has the state changed *case*, and if it is still a picture, is it still the
/// same picture object. A replaced decode is a different object, which is exactly the
/// case that has to redraw.
enum ClipVisualStateComparison {
    static func same(_ lhs: ClipVisualState, _ rhs: ClipVisualState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            return true
        case (.unavailable(let a), .unavailable(let b)):
            return a == b
        case (.ready(let a), .ready(let b)):
            return a.image === b.image
                && a.files.count == b.files.count
                && a.overflowFileCount == b.overflowFileCount
                && zip(a.files, b.files).allSatisfy { $0.id == $1.id && $0.missing == $1.missing }
        default:
            return false
        }
    }
}

/// Everything a row does, as opposed to everything it looks like.
///
/// Lifted out of the list so a thumbnail inside a contact sheet can take exactly the
/// same set — the drags, the drops, the hover, the click and the context menu are about
/// what a clipboard entry *is*, and none of them care whether it is drawn as a stripe or
/// as a picture.
private struct ClipRowBehaviour: ViewModifier {
    /// Held, not observed. Everything this modifier *draws* comes from the row it wraps,
    /// which is `Equatable` and compared; what it needs the model for is the drop
    /// delegate, the two appearance callbacks and the context menu, all of which read the
    /// model at the moment they run rather than when the view is built. Observing it here
    /// would put a per-row invalidation back on every change the panel publishes — the
    /// context menu alone is twenty-odd buttons per row.
    let model: ClipboardPanelModel
    let actions: ClipboardPanelActions
    let record: ClipRecord
    let index: Int

    /// The kinds whose content is text, and so can be rewritten on the way out.
    private static let textual: Set<ClipKind> = [.text, .richText, .url]

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // `.onDrag` and a tap gesture coexist: the drag needs the pointer to travel
            // before it takes over, so a stationary ⌘- or ⌥-click still reaches
            // `activateRow`.
            .modifier(ClipRowDragSource(record: record, index: index, actions: actions))
            // Both halves of the panel's drag-and-drop, on every row rather than only on
            // the ones that can be reordered: which of the two a drop means is decided
            // from the drag itself, and a modifier that came and went with the tab would
            // give the row a new identity every time the filter changed.
            .onDrop(
                of: clipRowDropTypes,
                delegate: ClipDropTarget(index: index, model: model, actions: actions)
            )
            // The selection follows the pointer, so what ↩ or a click acts on is always
            // the row being looked at.
            .onHover { inside in
                if inside { actions.hoverIndex(index) } else { actions.hoverEnded(index) }
            }
            // What a click means depends on the modifiers held, and reading those is not
            // something the view can do reliably — see `modifiersHeld()`. It reports the
            // click and lets the controller decide.
            .onTapGesture { actions.activateRow(index) }
            .onAppear { model.visualDidAppear(record) }
            .onDisappear { model.visualDidDisappear(record) }
            .contextMenu {
                Button("粘贴（原样）") {
                    actions.selectIndex(index)
                    actions.pasteAs(.original)
                }
                Button("连续粘贴（原样，不关闭）") {
                    actions.selectIndex(index)
                    actions.pasteKeepingOpen()
                }
                Menu("选择粘贴格式") {
                    ForEach(PasteAsMode.allCases) { mode in
                        Button(mode.label) {
                            actions.selectIndex(index)
                            actions.pasteAs(mode)
                        }
                    }
                }
                // Only where there is text to rewrite. A picture has no upper case, and
                // a file entry's paths are not the user's to reshape.
                if Self.textual.contains(record.kind) {
                    Menu("文本转换后粘贴") {
                        ForEach(PasteTransform.allCases) { transform in
                            Button(transform.label) {
                                actions.selectIndex(index)
                                actions.pasteTransformed(transform)
                            }
                        }
                    }
                }
                Button("只复制，不粘贴") { actions.selectIndex(index); actions.copyOnly() }
                // Rich text is left out on purpose: saving would flatten it to plain
                // text, and silently losing the styling is not something an "编辑…"
                // should do.
                if record.kind == .text || record.kind == .url, !record.oversized {
                    Button("编辑…") { actions.selectIndex(index); actions.edit() }
                }
                Divider()
                // On the queue tab the useful queue actions are the ones that reorder
                // it; "加入批量队列" there would only move the row to the end, which is
                // not what anyone means by it.
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
                // The 收藏 band is dragged into order, and this is the same move for
                // anyone not using a pointer — and the only way VoiceOver has of making
                // it at all. Offered only where the list *is* the band: see
                // `canReorderPinned`.
                if model.canReorderPinned {
                    Button("上移") { actions.reorderPinned(index, true) }
                    Button("下移") { actions.reorderPinned(index, false) }
                }
                Divider()
                Button("删除", role: .destructive) {
                    actions.selectIndex(index)
                    actions.delete()
                }
            }
    }
}

/// SwiftUI's `.onDrag` closure can publish only one provider. That is correct for text,
/// images and links, but structurally incapable of representing a clipboard entry that
/// contains several Finder objects. File rows therefore use a small AppKit source which
/// starts one `NSDraggingSession` containing all providers bundled behind the primary;
/// every other row stays on SwiftUI's native path.
private struct ClipRowDragSource: ViewModifier {
    let record: ClipRecord
    let index: Int
    let actions: ClipboardPanelActions

    @ViewBuilder
    func body(content: Content) -> some View {
        if record.kind == .files {
            content.overlay(
                MultiFileDragBridge(
                    makePrimary: { actions.dragBegan(record) },
                    activate: { actions.activateRow(index) },
                    hover: { inside in
                        if inside { actions.hoverIndex(index) } else { actions.hoverEnded(index) }
                    }
                )
            )
        } else {
            content.onDrag { actions.dragBegan(record) }
        }
    }
}

private struct MultiFileDragBridge: NSViewRepresentable {
    let makePrimary: () -> NSItemProvider
    let activate: () -> Void
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> MultiFileDragNSView {
        let view = MultiFileDragNSView()
        view.makePrimary = makePrimary
        view.activate = activate
        view.hover = hover
        return view
    }

    func updateNSView(_ view: MultiFileDragNSView, context: Context) {
        view.makePrimary = makePrimary
        view.activate = activate
        view.hover = hover
    }
}

final class MultiFileDragNSView: NSView, NSDraggingSource {
    var makePrimary: (() -> NSItemProvider)?
    var activate: (() -> Void)?
    var hover: ((Bool) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var startedDragging = false
    private var tracking: NSTrackingArea?
    private var activePrimary: NSItemProvider?
    /// Test seam for exercising the real `hitTest` override without dispatching a
    /// synthetic application event. Production always reads AppKit's current event.
    var hitTestEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    /// Leave scrolling, context menus and incoming drop hit-testing to the SwiftUI row
    /// underneath. Only the left-button sequence is owned by this bridge.
    func containsLocalPoint(_ point: NSPoint) -> Bool { bounds.contains(point) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let type = hitTestEventType() else { return nil }
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            // NSView's hit-test contract passes the point in the receiver's superview
            // coordinates. Convert exactly once before comparing it with local bounds.
            let local = superview.map { convert(point, from: $0) } ?? point
            return containsLocalPoint(local) ? self : nil
        default:
            return nil
        }
    }

    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, let origin = mouseDownPoint,
              hypot(
                  convert(event.locationInWindow, from: nil).x - origin.x,
                  convert(event.locationInWindow, from: nil).y - origin.y
              ) >= 3,
              let primary = makePrimary?()
        else { return }

        let items = ClipDragItem.draggingItems(representedBy: primary, at: origin)
        guard !items.isEmpty else { return }
        startedDragging = true
        activePrimary = primary
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !startedDragging { activate?() }
        mouseDownPoint = nil
        startedDragging = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        if let activePrimary { ClipDragItem.releaseBundle(representedBy: activePrimary) }
        activePrimary = nil
        mouseDownPoint = nil
        // Leave this true until the next mouse-down. Some AppKit versions deliver the
        // terminating mouse-up after this callback; clearing it here would turn the end
        // of a drag into an unintended row activation.
    }
}

/// One entry, drawn as whatever kind of thing it is.
///
/// The old row was one shape for everything: a 34pt tile, a title, a subtitle. It read
/// evenly and it told you almost nothing at a glance — a list of screenshots and a list
/// of shell commands were the same grey ladder. This one gives each kind the gutter that
/// identifies it (Aa, ❯, a favicon, a coloured file plate, the colour itself) and one
/// line of content, and moves everything the subtitle used to carry — where it came
/// from, how long ago, how big — into the preview card a hover already opens. Twice as
/// many rows fit, and which is which is legible without reading any of them.
private struct ResultRow: View, Equatable {
    let record: ClipRecord
    let index: Int
    let selected: Bool
    let checked: Bool
    let queued: Bool
    /// Set only on the queue tab: the row's place in the dispensing order, which is also
    /// the digit ⌘n reaches it by.
    let queuePosition: Int?
    let visualState: ClipVisualState
    let terms: [String]
    /// Set when the hit is not visible in the preview, and this snippet is why the row
    /// is in the list at all — so it takes a second line, which a row otherwise does not
    /// have.
    let context: String?
    /// Pinyin/initial and fuzzy hits have no literal UTF-16 range to colour. This line
    /// is the visible reason the row matched, and is repeated in its VoiceOver label.
    let matchNote: String?
    /// Everything the row draws that its record alone decides: the line it shows, the
    /// host chip, the file plate, what VoiceOver is told. Derived once per published
    /// list — see `RowPresentation`.
    let presentation: RowPresentation
    let theme: ClipPanelTheme
    let reduceMotion: Bool
    /// The hover buttons. One row each, never the ticked set — see `act(onRow:_:)`.
    let onPin: () -> Void
    let onDelete: () -> Void
    /// What the second button does on the queue tab instead of deleting — see `rowEnd`.
    let onDequeue: () -> Void

    @State private var hovering = false

    /// Everything the row is drawn from, and nothing else.
    ///
    /// The three closures are deliberately not compared — closures cannot be, and these
    /// are rebuilt identical on every pass. `record` carries its own `==`, which compares
    /// the identity, the date, the star and the digest; the digest is what stands in for
    /// the body, so an entry rewritten in the editor is not equal to itself before the
    /// edit. `visualState` is compared by which case it is and, for a decoded picture, by
    /// the identity of the image object — a thumbnail that has been replaced has to
    /// redraw, and comparing two `NSImage`s any other way would mean comparing pixels.
    static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.record == rhs.record
            // `ClipRecord`'s own `==` is identity, date, star and digest — enough to know
            // it is the same entry, but not everything this row *draws*. These five all
            // pick a shape rather than a string: the gutter mark, the typeface, the
            // swatch, the warning triangle, and how long a line has to be before the
            // selected row expands to three of them. In practice a digest carries them,
            // but "in practice" is how a row ends up drawn as the wrong kind of thing.
            && lhs.record.kind == rhs.record.kind
            && lhs.record.preview == rhs.record.preview
            && lhs.record.contentTag == rhs.record.contentTag
            && lhs.record.colorHex == rhs.record.colorHex
            && lhs.record.oversized == rhs.record.oversized
            && lhs.index == rhs.index
            && lhs.selected == rhs.selected
            && lhs.checked == rhs.checked
            && lhs.queued == rhs.queued
            && lhs.queuePosition == rhs.queuePosition
            && lhs.terms == rhs.terms
            && lhs.context == rhs.context
            && lhs.matchNote == rhs.matchNote
            && lhs.presentation == rhs.presentation
            && lhs.theme == rhs.theme
            && lhs.reduceMotion == rhs.reduceMotion
            && ClipVisualStateComparison.same(lhs.visualState, rhs.visualState)
    }

    /// The gutter every kind draws its identifying mark in.
    private static let gutter: CGFloat = 32

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            if let queuePosition {
                Text("\(queuePosition)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .frame(width: 14, alignment: .trailing)
            }
            leading
            content
            rowEnd
        }
        .padding(.horizontal, 10)
        .padding(.vertical, verticalPadding)
        // Instant. The highlight used to fade in over 0.1s, from when the selected row
        // was painted in the accent colour and a hard switch was jarring; now hovering a
        // row *is* selecting it, so that fade ran on every row the pointer crossed and
        // left a comet's tail of half-lit rows behind a quick sweep. The highlight has to
        // be under the pointer by the time the eye arrives.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    borderColour,
                    // Never thinner than the palette asks for: under "increase contrast"
                    // a hairline is exactly the thing that disappears.
                    lineWidth: max(theme.borderWidth, checked && !selected ? 1.5 : 1)
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
        // The queue tab's own button, offered alongside 删除 rather than in place of it:
        // VoiceOver never hovers, so the rotor is the only place either of them exists.
        .accessibilityActions {
            if queuePosition != nil {
                Button("移出队列", action: onDequeue)
            }
        }
    }

    // MARK: Shape

    /// A text row that has grown to three lines, or one carrying a search snippet, is
    /// taller than its gutter mark: the mark belongs at the top of it rather than
    /// floating in the middle of a paragraph.
    private var alignment: VerticalAlignment {
        (isMultiline || secondLine != nil) ? .top : .center
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .image: return 7
        case .colour: return 6
        default: return isMultiline || secondLine != nil ? 9 : 8
        }
    }

    /// Expanded text: the selected row shows three lines of a long entry where every
    /// other row shows one. It is the cheapest possible preview, it costs nothing when
    /// the entry is short, and it is what makes ↑↓ down a list of paragraphs readable.
    private var isMultiline: Bool {
        selected && style == .text && record.preview.count > 34
    }

    private enum Style { case text, code, link, file, colour, image }

    private var style: Style {
        switch record.kind {
        case .image: return .image
        case .files: return .file
        case .url: return .link
        case .color: return .colour
        case .text, .richText:
            return record.contentTag?.prefersMonospace == true ? .code : .text
        }
    }

    private var background: Color {
        if selected { return theme.selectionFill }
        if checked { return theme.checkedFill }
        if hovering { return theme.selectionFill.opacity(0.6) }
        return .clear
    }

    private var borderColour: Color {
        if checked && !selected { return theme.accent.opacity(0.7) }
        if selected { return theme.selectionBorder }
        return .clear
    }

    // MARK: Gutter

    @ViewBuilder
    private var leading: some View {
        switch style {
        case .text:
            gutterMark {
                Text("Aa")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
        case .code:
            gutterMark {
                Text("❯")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.code)
            }
        case .link:
            gutterMark {
                Text(faviconLetter)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.accent.opacity(0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
                    )
            }
        case .file:
            FileTypePlate(ext: fileExtension)
        case .colour:
            gutterMark {
                Circle()
                    .fill(swatch ?? theme.tile)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
            }
        case .image:
            // The single-picture row indents to where a gutter would have been and then
            // shows the picture itself at a size worth looking at. A 34pt tile of a
            // screenshot is a grey square.
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func gutterMark<Mark: View>(@ViewBuilder _ mark: () -> Mark) -> some View {
        mark()
            .frame(width: Self.gutter, alignment: .center)
            .padding(.top, alignment == .top ? 2 : 0)
            .accessibilityHidden(true)
    }

    /// The colour a colour entry paints, for the rows that have one.
    private var swatch: Color? {
        guard record.kind == .color, let hex = record.colorHex,
              let value = ClipColorValue(hex: hex)
        else { return nil }
        return Color(nsColor: value.nsColor)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch style {
        case .image:
            imageContent
        case .colour:
            colourContent
        case .link:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    titleText
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let host = linkHost {
                        Text(host)
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(theme.accent.opacity(0.13)))
                            .fixedSize()
                    }
                }
                secondLineView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .file:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    titleText
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if let folder = fileFolder {
                        Text(folder)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
                    }
                }
                secondLineView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .text, .code:
            VStack(alignment: .leading, spacing: 3) {
                titleText
                    .font(
                        style == .code
                            ? .system(size: 11.5, design: .monospaced)
                            : .system(size: 12.5)
                    )
                    .foregroundStyle(style == .code ? theme.code : theme.text)
                    .lineLimit(isMultiline ? 3 : 1)
                    .lineSpacing(isMultiline ? 2.5 : 0)
                    .multilineTextAlignment(.leading)
                secondLineView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var imageContent: some View {
        HStack(spacing: 0) {
            ClipThumbnail(
                record: record, state: visualState, theme: theme, cornerRadius: 10
            )
            // A fixed window onto the picture rather than the picture's own shape: a
            // list whose row heights followed whatever was copied would be impossible to
            // aim at, and a panorama would own the whole panel.
            .frame(maxWidth: 216, minHeight: 104, maxHeight: 104)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colourContent: some View {
        HStack(spacing: 6) {
            Text(record.colorHex ?? record.preview)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Spacer(minLength: 0)
            if record.pinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(swatch ?? theme.tile)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
        )
    }

    /// The one line a row keeps beneath its title, and only when a search put it there.
    ///
    /// Nothing else earns a second line any more: 「ChatGPT · 15 小时前」 under every entry
    /// was the same two facts repeated down the whole panel, and both of them are in the
    /// card a hover opens. A search hit is different — it is *why this row is here*, and
    /// a row that cannot say that is a result you have to take on trust.
    private var secondLine: String? { matchNote ?? context }

    @ViewBuilder
    private var secondLineView: some View {
        if let matchNote {
            Label(matchNote, systemImage: "text.magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .accessibilityLabel(matchNote)
        } else if let context {
            Text(contextText(context))
                .font(.system(size: 10))
                .lineLimit(1)
        }
    }

    private func contextText(_ context: String) -> AttributedString {
        guard !terms.isEmpty else {
            var text = AttributedString(context)
            text.foregroundColor = theme.text3
            return text
        }
        return ClipHighlight.make(
            context,
            terms: terms,
            emphasis: .system(size: 10, weight: .semibold),
            plain: theme.text3,
            dimmed: theme.text3,
            accent: theme.accent
        )
    }

    /// With nothing typed there are no hits to paint, and an `AttributedString` would be
    /// an allocation and a copy of the whole 400-character preview per row — paid again on
    /// every list rebuild, which a hover, a clock tick or a copy in another application
    /// all cause. A plain `Text` draws the identical line for nothing.
    @ViewBuilder
    private var titleText: some View {
        if terms.isEmpty {
            Text(displayTitle)
        } else {
            Text(highlightedTitle)
        }
    }

    private var highlightedTitle: AttributedString {
        ClipHighlight.make(
            displayTitle,
            terms: terms,
            emphasis: .system(
                size: style == .code ? 11.5 : 12.5,
                weight: .semibold,
                design: style == .code ? .monospaced : .default
            ),
            plain: style == .code ? theme.code : theme.text,
            dimmed: style == .code ? theme.code : theme.text,
            accent: theme.accent
        )
    }

    // MARK: Link and file decomposition

    /// What the row's one line says.
    ///
    /// A file entry shows its own name rather than the whole path, which is what the
    /// folder chip beside it is for; a link shows everything *after* the host, for the
    /// same reason — the domain chip at the other end of the row is already saying
    /// google.com, and a line that began by repeating it would spend its width on the
    /// half that is already known and truncate the half that is not.
    ///
    /// All of it, and the four file-path components below, are read from
    /// `RowPresentation`: they were computed properties here, which meant a link row
    /// parsed its own URL three times over on every pass the panel made.
    private var displayTitle: String { presentation.displayTitle }
    private var linkHost: String? { presentation.linkHost }
    private var faviconLetter: String { presentation.faviconLetter }
    private var fileFolder: String? { presentation.fileFolder }
    private var fileExtension: String { presentation.fileExtension }

    // MARK: Trailing

    /// What VoiceOver reads: what kind of thing it is, what it says, where it came from
    /// and how long ago — in that order, because the first two are what identifies the
    /// row and the rest only tells them apart.
    ///
    /// Deliberately unchanged by the redesign. The rows gave up their subtitles to the
    /// preview card, which is a *visual* economy: someone listening to the list never had
    /// a hover to spend, and taking the source and the age out of here would have made
    /// the panel worse for them to pay for making it denser for everyone else.
    private var spokenLabel: String {
        var parts: [String] = []
        if let queuePosition { parts.append("队列第 \(queuePosition) 条") }
        // Kind, content and source, worked out once for the list rather than once per
        // row per frame.
        parts.append(presentation.spokenPrefix)
        if let matchNote { parts.append(matchNote) }
        // Present exactly when VoiceOver is running, which is exactly when this string
        // is read — see `RowPresentation.spokenTime`.
        if let age = presentation.spokenTime { parts.append(age) }
        if record.pinned { parts.append("已收藏") }
        if checked { parts.append("已选中") }
        if queued, queuePosition == nil { parts.append("在队列中") }
        return parts.joined(separator: "，")
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
                        action: onPin
                    )
                    // On the queue tab this button is the queue's, not the history's.
                    // ⌘⌫, the context menu and the batch keys all mean 「移出队列」 there
                    // and leave the entry in the history; a trash beside them that quietly
                    // destroyed it would be the one irreversible thing on the tab, and the
                    // one nobody would expect from a row they only wanted out of the way.
                    if queuePosition == nil {
                        RowActionButton(
                            symbol: "trash",
                            label: "删除",
                            hint: "删除这一条（⌘Z 可撤销）",
                            tint: nil,
                            action: onDelete
                        )
                    } else {
                        RowActionButton(
                            symbol: "minus.circle",
                            label: "移出队列",
                            hint: "移出队列（⌘⌫）· 历史里还留着",
                            tint: nil,
                            action: onDequeue
                        )
                    }
                }
            } else {
                HStack(spacing: 5) {
                    if record.oversized {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("这条内容超过了单条上限，没有保存正文")
                    }
                    // Both of these are about the queue, and on the queue tab every row
                    // is in it: the leading number already says so, and says where.
                    if queued, queuePosition == nil {
                        Image(systemName: "text.append")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                    if record.pinned, style != .colour {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    // The queue tab's leading number is the same digit; two of them on
                    // one row would read as two different positions.
                    if index < 9, queuePosition == nil {
                        Text("⌘\(index + 1)")
                            .font(.system(size: 10, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? theme.text2 : theme.text3)
                    }
                }
            }
        }
        .frame(width: 42, alignment: .trailing)
        .padding(.top, alignment == .top ? 1 : 0)
    }
}

/// A run of pictures, drawn as a contact sheet.
///
/// Ten screenshots in a row is the case the old list handled worst: ten near-identical
/// stripes, each with a 34pt grey square, none of them telling you which was which
/// without hovering every one. Three across, at four-by-three, they are recognisable
/// from the list itself — and a ⌘-drag across them selects a set the way selecting
/// pictures works everywhere else on the machine.
private struct ImageGridBlock: View {
    let range: Range<Int>
    @ObservedObject var model: ClipboardPanelModel
    let actions: ClipboardPanelActions

    @Environment(\.panelTheme) private var theme

    private static let gap: CGFloat = 8

    var body: some View {
        ImageGridSizingLayout(count: range.count) {
            GeometryReader { proxy in
                let metrics = ImageGridMetrics(width: proxy.size.width, count: range.count)
                // Where this sheet is in the list's own coordinate space, and which rows it
                // holds there. A band dragged across two sheets is resolved in that space,
                // against every sheet on screen — see `ClipMarqueeResolver`.
                let registration = ClipSheetRegistration(
                    range: range,
                    frame: proxy.frame(in: .named(ClipListSpace.name)),
                    metrics: metrics
                )
                ZStack(alignment: .topLeading) {
                    ForEach(Array(range), id: \.self) { index in
                        cell(at: index, metrics: metrics)
                            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                            .offset(
                                x: metrics.origin(of: index - range.lowerBound).x,
                                y: metrics.origin(of: index - range.lowerBound).y
                            )
                    }
                    // Over the cells, and transparent to everything except a ⌘-drag — see
                    // `GridMarqueeView`. A SwiftUI gesture could not be used here: the cells
                    // are drag *sources*, and a rubber band and an `.onDrag` competing for
                    // the same button would make one of them unreliable.
                    GridMarqueeView(
                        metrics: metrics,
                        origin: registration.frame.origin,
                        accent: NSColor(theme.accent),
                        onSelect: { band in model.applyMarquee(band) },
                        onClear: { model.setChecked([]) }
                    )
                }
                // Registered rather than published: this is a plain dictionary write on the
                // model, read only while a band is actually being dragged. It has to follow
                // the sheet as the list scrolls, which is why it is not only `onAppear`.
                //
                // The whole registration is watched, not just the frame. Deleting a picture
                // inside a long run shortens this block — `12..<17` becomes `12..<16` — while
                // leaving its first row, and so its view identity, alone: no `onAppear`. Five
                // pictures and four are both two lines, so the frame does not move either. A
                // frame-only watch would leave the model holding a range the list no longer
                // has, which `sheetRegistrations` rightly refuses to trust, and the sheet
                // would stop answering the rubber band until the panel was reopened.
                .onAppear { model.registerSheet(registration) }
                .onChange(of: registration) { model.registerSheet($0) }
                .onDisappear { model.unregisterSheet(range) }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(range.count) 张图片")
    }

    @ViewBuilder
    private func cell(at index: Int, metrics: ImageGridMetrics) -> some View {
        if let record = model.results.indices.contains(index) ? model.results[index] : nil {
            cell(record, at: index, metrics: metrics)
        }
    }

    @ViewBuilder
    private func cell(_ record: ClipRecord, at index: Int, metrics: ImageGridMetrics) -> some View {
        let selected = index == model.selectedIndex
        let ordinal = model.checkedOrdinal(of: record.id)
        ClipThumbnail(record: record, state: model.visualState(for: record), theme: theme)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        ordinal != nil ? theme.accent : (selected ? theme.selectionBorder : .clear),
                        lineWidth: ordinal != nil ? 2 : 1.5
                    )
            )
            .overlay(alignment: .topTrailing) {
                if let ordinal {
                    Text("\(ordinal)")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(theme.dark ? Color(white: 0.07) : .white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(theme.accent))
                        .padding(4)
                }
            }
            // Only on the picked ones. A `shadow` modifier costs an offscreen pass
            // whether or not its colour is visible, and this one sat on every cell of
            // every sheet, redrawn whenever anything in the panel published a change.
            .modifier(SelectedGlow(active: ordinal != nil, colour: theme.accent))
            .modifier(
                ClipRowBehaviour(
                    model: model, actions: actions, record: record, index: index
                )
            )
            .accessibilityLabel(thumbnailLabel(record, index: index, ordinal: ordinal))
    }

    private func thumbnailLabel(_ record: ClipRecord, index: Int, ordinal: Int?) -> String {
        var parts = ["图片", "第 \(index - range.lowerBound + 1) 张"]
        if let name = record.sourceName, !name.isEmpty { parts.append(name) }
        // Only where it will be read: the age is computed for the list exactly when
        // VoiceOver is running — see `RowPresentation.spokenTime`. Every cell of every
        // sheet asking `relativeTime` on every frame, for a string nobody was listening
        // to, is a `DateFormatter` per old screenshot per pass.
        if let age = model.presentation(for: record).spokenTime { parts.append(age) }
        if let ordinal { parts.append("已选中，第 \(ordinal) 个") }
        return parts.joined(separator: "，")
    }
}

/// Gives the geometry reader the height implied by the exact width SwiftUI proposed.
///
/// Computing that height from `model.panelWidth` was subtly wrong whenever the scroll
/// view reserved space for its scroller: the reader became a few points narrower, so the
/// cells it drew were shorter than the frame the stack had reserved. Besides leaving a
/// strip of dead space under every line, that made the registered marquee coordinates
/// disagree with the cells. A `Layout` sees the final proposed content width after both
/// the scroll view and this block's padding, so one `ImageGridMetrics` calculation now
/// determines both dimensions.
private struct ImageGridSizingLayout: Layout {
    let count: Int

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        return CGSize(width: width, height: ImageGridMetrics(width: width, count: count).totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Where every cell of a contact sheet is, given how wide the sheet is.
///
/// Shared by the SwiftUI layout and the AppKit rubber band, which is the whole point:
/// two independent ideas of where the cells are would be a marquee that selects the
/// wrong pictures, and it would drift as soon as either side was edited.
struct ImageGridMetrics: Equatable {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let gap: CGFloat
    let count: Int
    let columns: Int

    init(width: CGFloat, count: Int, gap: CGFloat = 8) {
        self.columns = ClipPanelLayout.gridColumns
        self.gap = gap
        self.count = count
        let available = max(width - gap * CGFloat(columns - 1), CGFloat(columns))
        cellWidth = (available / CGFloat(columns)).rounded(.down)
        // 4:3, the proportion most screenshots and photographs are nearer to than a
        // square, and tall enough that a portrait shot is still recognisable cropped.
        cellHeight = (cellWidth * 3 / 4).rounded()
    }

    var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }

    var totalHeight: CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap
    }

    func origin(of offset: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(offset % columns) * (cellWidth + gap),
            y: CGFloat(offset / columns) * (cellHeight + gap)
        )
    }

    func frame(of offset: Int) -> CGRect {
        CGRect(origin: origin(of: offset), size: CGSize(width: cellWidth, height: cellHeight))
    }

    /// Which cells a rubber band touches, in list order — which is the order the badges
    /// count in and the order a batch is acted on.
    func hits(in rect: CGRect) -> [Int] {
        (0..<count).filter { frame(of: $0).intersects(rect) }
    }
}

/// The ring around a thumbnail that has been picked, and nothing at all around one that
/// has not.
private struct SelectedGlow: ViewModifier {
    let active: Bool
    let colour: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.shadow(color: colour.opacity(0.3), radius: 4)
        } else {
            content
        }
    }
}

/// The coordinate space every contact sheet reports its frame in, and the one a rubber
/// band is resolved in. The list's own, so scrolling moves sheets and band together.
enum ClipListSpace {
    static let name = "hyper.clip.list"
}

/// One contact sheet, as the rubber band sees it: which rows it holds, where it is, and
/// how its cells are laid out inside it.
///
/// Registered by each sheet as it is laid out — see `ImageGridBlock` — and read only when
/// a band is actually being dragged.
struct ClipSheetRegistration: Equatable {
    /// Half-open, in the same indices as `results`.
    let range: Range<Int>
    /// In `ClipListSpace`: top-left origin, y downwards, exactly as SwiftUI reports it
    /// and exactly as the flipped marquee view measures its own band.
    let frame: CGRect
    let metrics: ImageGridMetrics
}

/// Which rows a rubber band touches, across every sheet it crosses.
///
/// A long run of pictures is drawn as several sheets so the list can virtualise them —
/// see `ClipPanelLayout.maxGridRun` — and each sheet has a marquee view of its own. But a
/// mouse sequence belongs to the view that took the press, so a band started in one sheet
/// and dragged into the next was being resolved against only the first sheet's cells, in
/// only the first sheet's coordinates: everything past the seam selected nothing. The
/// band is therefore resolved *here*, in the list's coordinates, against every sheet on
/// screen — which is also the only form of the question that can be asked without a
/// window.
enum ClipMarqueeResolver {
    /// In list order, which is the order the badges count in and a batch is acted on.
    static func hits(in band: CGRect, sheets: [ClipSheetRegistration]) -> [Int] {
        var hits: [Int] = []
        for sheet in sheets {
            guard band.intersects(sheet.frame) else { continue }
            // Into the sheet's own coordinates, where its metrics can answer.
            let local = band.offsetBy(dx: -sheet.frame.minX, dy: -sheet.frame.minY)
            for offset in sheet.metrics.hits(in: local) {
                let index = sheet.range.lowerBound + offset
                guard sheet.range.contains(index) else { continue }
                hits.append(index)
            }
        }
        return hits.sorted()
    }
}

private struct GridMarqueeView: NSViewRepresentable {
    let metrics: ImageGridMetrics
    /// Where this sheet sits in `ClipListSpace`, so the band it draws can be reported in
    /// the one coordinate space every sheet shares.
    let origin: CGPoint
    let accent: NSColor
    let onSelect: (CGRect) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> GridMarqueeNSView {
        let view = GridMarqueeNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: GridMarqueeNSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: GridMarqueeNSView) {
        view.metrics = metrics
        view.listOrigin = origin
        view.accent = accent
        view.onSelect = onSelect
        view.onClear = onClear
    }
}

/// The rubber band over a contact sheet.
///
/// Invisible and untouchable until a ⌘-drag begins, which is the one thing that makes it
/// safe to lay over cells that are themselves drag sources: `hitTest` claims the pointer
/// only for a left-button press with ⌘ held, so an ordinary click, an ordinary drag out
/// to another application, a scroll and a right-click all pass straight through to the
/// SwiftUI cell underneath. Once a press is claimed, AppKit routes the rest of that
/// mouse sequence here regardless of hit-testing, which is what lets the band track.
final class GridMarqueeNSView: NSView {
    var metrics = ImageGridMetrics(width: 300, count: 0)
    /// This sheet's origin in `ClipListSpace`. The band is drawn in local coordinates and
    /// reported in list coordinates, because it may well end up over another sheet.
    var listOrigin: CGPoint = .zero
    var accent: NSColor = .controlAccentColor
    /// The band, in `ClipListSpace`.
    var onSelect: ((CGRect) -> Void)?
    var onClear: (() -> Void)?
    /// Test seam, matching `MultiFileDragNSView`: production always reads AppKit's
    /// current event.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    private var anchor: NSPoint?
    private var band: CALayer?
    private var lastBand: CGRect?

    /// Top-down, so the rectangle this view works in is the same one SwiftUI laid the
    /// cells out in and `ImageGridMetrics` can be shared between them verbatim.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = currentEvent(), event.type == .leftMouseDown,
              event.modifierFlags.contains(.command)
        else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        lastBand = nil
        // A band is a live rubber band, not an addition: it starts from nothing and rows
        // have to leave the selection as it is dragged back over them.
        onClear?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let current = convert(event.locationInWindow, from: nil)
        // Deliberately not clipped to `bounds`: the band may be dragged past this sheet
        // into the next one, and the whole point of reporting it in list coordinates is
        // that the part hanging outside is still a real part of the band.
        let rect = NSRect(
            x: min(anchor.x, current.x), y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x), height: abs(current.y - anchor.y)
        )
        show(rect)
        let listBand = rect.offsetBy(dx: listOrigin.x, dy: listOrigin.y)
        guard listBand != lastBand else { return }
        lastBand = listBand
        onSelect?(listBand)
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        lastBand = nil
        band?.removeFromSuperlayer()
        band = nil
    }

    private func show(_ rect: NSRect) {
        wantsLayer = true
        let layer: CALayer
        if let band {
            layer = band
        } else {
            layer = CALayer()
            layer.borderWidth = 1.5
            layer.cornerRadius = 6
            layer.borderColor = accent.withAlphaComponent(0.9).cgColor
            layer.backgroundColor = accent.withAlphaComponent(0.12).cgColor
            self.layer?.addSublayer(layer)
            band = layer
        }
        // No implicit animation: a rubber band that eases towards the pointer lags it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = rect
        CATransaction.commit()
    }
}

/// The coloured plate a file row wears instead of a gutter mark.
///
/// The extension, in the colour the format is recognised by — Photoshop blue, Acrobat
/// red, archive amber. It reads at a glance in a way `doc.on.doc` in grey never did,
/// which matters most on the lists where every row is a file.
private struct FileTypePlate: View {
    let ext: String

    @Environment(\.panelTheme) private var theme

    private static let palette: [String: (Color, Color)] = [
        "PSD": (Color(red: 0.35, green: 0.59, blue: 1.0), Color(red: 0.18, green: 0.43, blue: 0.88)),
        "AI": (Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 0.85, green: 0.40, blue: 0.10)),
        "PDF": (Color(red: 1.0, green: 0.48, blue: 0.43), Color(red: 0.88, green: 0.25, blue: 0.18)),
        "ZIP": (Color(red: 1.0, green: 0.82, blue: 0.40), Color(red: 0.91, green: 0.64, blue: 0.15)),
        "MP4": (Color(red: 0.72, green: 0.54, blue: 1.0), Color(red: 0.49, green: 0.31, blue: 0.88)),
        "MOV": (Color(red: 0.72, green: 0.54, blue: 1.0), Color(red: 0.49, green: 0.31, blue: 0.88)),
        "PNG": (Color(red: 0.38, green: 0.85, blue: 0.72), Color(red: 0.16, green: 0.64, blue: 0.55)),
        "JPG": (Color(red: 0.38, green: 0.85, blue: 0.72), Color(red: 0.16, green: 0.64, blue: 0.55)),
        "SWIFT": (Color(red: 1.0, green: 0.60, blue: 0.40), Color(red: 0.90, green: 0.33, blue: 0.16)),
    ]

    var body: some View {
        Text(ext)
            .font(.system(size: 9, weight: .heavy))
            .kerning(0.5)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 32, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [colours.0, colours.1],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    private var colours: (Color, Color) {
        Self.palette[ext] ?? (Color(white: 0.63), Color(white: 0.44))
    }
}

/// A stored thumbnail, with somewhere to stand while it loads and something to say when
/// it cannot be had. Shared by the picture row and every cell of a contact sheet.
private struct ClipThumbnail: View {
    let record: ClipRecord
    let state: ClipVisualState
    let theme: ClipPanelTheme
    var cornerRadius: CGFloat = 9

    var body: some View {
        // The plate is the base and everything else is laid *over* it, rather than the
        // whole thing being a `ZStack`. A `ZStack` takes the size of its largest child,
        // and a picture asked to fill a 4:3 cell reports the size it would need to cover
        // it — for a portrait screenshot that is half as tall again as the cell, so the
        // stack grew, the clip grew with it, and the thumbnail spilled over the rows
        // underneath. A `Shape` accepts exactly the size it is offered, which is the
        // cell, and the overlay is then measured against that.
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.tile)
            .overlay {
                switch state {
                case .ready(let asset):
                    if let image = asset.image {
                        Image(nsImage: image)
                            .resizable()
                            // The stored thumbnail is 720px on its longest side and this
                            // draws it far smaller. At the default interpolation that
                            // lands as aliased noise — a screenshot of text turns into
                            // speckle.
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        glyph(record.kind.symbolName)
                    }
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在加载预览")
                case .unavailable:
                    glyph("exclamationmark.triangle")
                case .idle:
                    glyph(record.kind.symbolName)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.tileBorder, lineWidth: theme.borderWidth)
            )
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(theme.text3)
            .accessibilityHidden(true)
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
    let action: () -> Void

    @Environment(\.panelTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(tint ?? theme.text2)
                // Without a filled shape behind it only the glyph's own strokes take the
                // click, which is a very small target for a 12pt icon.
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? theme.chip : Color.clear))
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
    /// The panel's wall clock. Observed here and nowhere else: the card's footer is the
    /// only thing left in the panel that shows a relative time, so it is the only thing
    /// that has to be redrawn when "刚刚" becomes "1 分钟前" — see `PanelClock`.
    @ObservedObject private var clock: PanelClock
    @State private var text: PreviewText?
    /// Built alongside the text rather than in `body`, because the attributed copy of a
    /// long document is not something to rebuild on every layout pass.
    @State private var highlighted: AttributedString?
    /// The styled rendering of an RTF entry, when there is one. Nil for everything else,
    /// and for the styled entries that were too large or failed to parse — those fall
    /// through to the plain-text pane below.
    @State private var rich: ClipRichText.Rendered?

    @Environment(\.panelTheme) private var theme

    init(model: ClipboardPanelModel) {
        self.model = model
        self.clock = model.previewClock
    }

    var body: some View {
        Group {
            if let record = model.previewRecord {
                VStack(alignment: .leading, spacing: 0) {
                    content(for: record)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                    PanelHairline()
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
                    // One read for both halves — see `ClipboardPanelModel.previewPayload`.
                    let loaded = await model.previewPayload(for: record)
                    guard !Task.isCancelled else { return }
                    // The styled half is published before `text` rather than after, so a
                    // styled entry does not show one frame of flat text and then redraw
                    // itself into the styled card. Until both have landed the pane stays
                    // blank, which is what it does for every other row too.
                    if let data = loaded.rich {
                        rich = ClipRichText.render(data)
                    }
                    guard !Task.isCancelled else { return }
                    text = loaded.text
                    // The preview is already capped at a couple of thousand characters,
                    // so marking it up is cheap enough to do right here.
                    if let body = loaded.text, !model.highlightTerms.isEmpty {
                        highlighted = ClipHighlight.make(
                            body.body,
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
        // Its own window, so it does not inherit the list's environment — it has to take
        // the same palette from the same place.
        .environment(\.panelTheme, model.theme)
        .foregroundStyle(model.theme.text)
        .tint(model.theme.accent)
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
            switch model.visualState(for: record) {
            case .ready(let asset) where asset.image != nil:
                if let image = asset.image {
                    ImagePreview(image: image) { model.openImageExternally(record) }
                }
            case .unavailable(let failure):
                notice(failure.message, detail: "原内容仍可复制或粘贴。", symbol: "photo.badge.exclamationmark")
            case .idle, .loading, .ready:
                loadingNotice("正在准备图片预览", symbol: "photo")
            }
        } else if let rich, record.kind == .richText {
            RichTextPreview(rendered: rich)
        } else if let value = colorValue(record) {
            ColorPreview(value: value, model: model)
        } else if record.kind == .url {
            // No wait for the payload: the stored preview line already *is* the URL, so
            // the pane can be right on the first frame instead of blank for 60ms.
            URLPreview(urlString: text?.body ?? record.preview)
        } else if record.kind == .files {
            switch model.visualState(for: record) {
            case .ready(let asset) where !asset.files.isEmpty:
                FilePreview(asset: asset, terms: model.highlightTerms)
            case .unavailable(let failure):
                notice(
                    failure.message,
                    detail: "网络卷、离线文件或已移除的项目不会阻塞面板。",
                    symbol: "doc.badge.ellipsis"
                )
            case .idle, .loading, .ready:
                loadingNotice("正在读取文件信息", symbol: "doc.on.doc")
            }
        } else if let text, !text.body.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(highlighted ?? AttributedString(text.body))
                        .font(.system(size: 12, design: design(record)))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if text.truncated {
                        Text("预览已截断 · 粘贴的仍是完整内容")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.text3)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
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

    private func loadingNotice(_ title: String, symbol: String) -> some View {
        VStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
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
            Text(metadataLine(for: record))
                .lineLimit(1)
            Spacer(minLength: 8)
            // What the card is for, said in the key that does it. The list no longer
            // carries a hint bar, so this is where the one action a preview leads to
            // gets named — and it is the only one, which is why it fits.
            HStack(spacing: 4) {
                Text("⌘C")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.keyCap)
                    )
                Text(record.kind == .image ? "复制原图" : "复制")
            }
            .fixedSize()
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metadataLine(for: record) + "。按 ⌘C 复制。")
    }

    /// One line, in the order someone reads it: what it is, where it came from, how big,
    /// when. This is where the rows' subtitles went — a single place that says it once,
    /// about the entry actually being looked at, instead of every row saying it about
    /// itself all the way down the panel.
    private func metadataLine(for record: ClipRecord) -> String {
        var parts: [String] = [record.contentTag?.label ?? record.kind.label]
        if record.kind == .image, let w = record.pixelWidth, let h = record.pixelHeight {
            parts.append("\(w)×\(h)")
        }
        if let stats = textStats(for: record) { parts.append(stats) }
        // Only where it is the size someone would want: a picture's or a file's. For
        // text the character count above already says how much there is, and 「54 字符 ·
        // 54 bytes」 is one fact twice — on the one line the card has for all of them.
        if record.byteSize > 0, record.kind == .image || record.kind == .files {
            parts.append(ClipByteSize.string(Int64(record.byteSize)))
        }
        if let name = record.sourceName, !name.isEmpty { parts.append(name) }
        parts.append(ClipRecord.relativeTime(from: record.createdAt, to: clock.now))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Preview panes

/// The picture, edge to edge.
///
/// The card is now cut to the picture's own proportion — see
/// `ClipboardPanelController.previewHeight(for:width:)` — so the picture fills it rather
/// than sitting on a mat inside it. The 「⌘C 复制原图」 line that used to sit under it has
/// moved into the card's footer, which says that for every kind of entry; what is left
/// is the one thing the footer cannot do, and it stays out of the way until the pointer
/// is on the card.
private struct ImagePreview: View {
    let image: NSImage
    let openExternally: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            // The stored thumbnail is 720px on its longest side and this pane may be
            // wider than that, so the picture is scaled *up* as often as down — which is
            // exactly where the default interpolation shows.
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button(action: openExternally) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(white: 0.08, opacity: 0.6)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .opacity(hovering ? 1 : 0)
                .help("把原图写到临时文件后交给「预览」打开")
                .accessibilityLabel("在预览程序中打开这张图片")
            }
            .onHover { hovering = $0 }
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
/// `ByteCountFormatter.string(fromByteCount:countStyle:)` is a class method that builds
/// and throws away a whole formatter on every call, and the file-preview card calls it
/// once per listed row on every body evaluation. One reused instance instead.
///
/// Main thread only: `ByteCountFormatter` is not thread-safe, and every caller here is a
/// SwiftUI `body`.
enum ClipByteSize {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

private struct FilePreview: View {
    private let rows: [Row]
    private let overflow: Int
    private let thumbnail: NSImage?

    private struct Row: Identifiable {
        let id: Int
        /// Marked up here rather than in `body`: the hit inside a long path is exactly
        /// what the search was for, and a name shown plain would look like a miss.
        let name: AttributedString
        let directory: AttributedString
        let missing: Bool
        let icon: NSImage
        /// Pre-decided by `ClipFilePreviewEntry.badge`, so a row that knows nothing about
        /// where its file lives shows nothing rather than claiming 「网络卷」.
        let badge: ClipFileBadge?
    }

    init(asset: ClipPreviewAsset, terms: [String]) {
        thumbnail = asset.image
        overflow = asset.overflowFileCount
        rows = asset.files.map { entry in
            return Row(
                id: entry.id,
                name: ClipHighlight.make(
                    entry.name,
                    terms: terms,
                    emphasis: .system(size: 12.5, weight: .semibold),
                    plain: entry.missing ? .red : .primary,
                    dimmed: entry.missing ? .red : .primary,
                    accent: .accentColor
                ),
                directory: ClipHighlight.make(
                    entry.directory,
                    terms: terms,
                    emphasis: .system(size: 10, weight: .semibold),
                    plain: .secondary,
                    dimmed: .secondary,
                    accent: .accentColor
                ),
                missing: entry.missing,
                icon: entry.icon,
                badge: entry.badge
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.bottom, 8)
                }
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(nsImage: row.icon)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .opacity(row.missing ? 0.45 : 1)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(row.name)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                switch row.badge {
                                case .missing:
                                    Text("已不存在")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(Color.red)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(Color.red.opacity(0.14))
                                        )
                                case .unreachable:
                                    Text("网络卷")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                case .size(let byteSize):
                                    Text(ClipByteSize.string(byteSize))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                case nil:
                                    EmptyView()
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

    @Environment(\.panelTheme) private var theme

    var body: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: hasQuery ? "magnifyingglass" : symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.text3)
            Text(hasQuery ? "没有匹配的内容" : title)
                .font(.system(size: 13, weight: .medium))
            if let detail = hasQuery ? searchDetail : detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
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

/// One key and what it does, as the shortcut sheet and the first-run card both draw it.
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

    @Environment(\.panelTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.map { $0.opacity(0.15) } ?? theme.keyCap)
                )
                .frame(width: keyWidth, alignment: .leading)
            Text(label)
                .font(.system(size: 10))
                // Wraps rather than truncates: the sheet's descriptions are the long
                // ones, and a column of them is narrow.
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint ?? theme.text2)
    }
}

/// What the panel says about itself, once, the first time it is ever opened.
///
/// Three lines and no more. The panel's whole shape follows from them — ↩ sends the row
/// you are on, ⌘-click sends several without closing, `?` has the rest — and everything
/// else it teaches by being used. A first-run sheet that tried to cover the other twenty
/// keys would be read by nobody, and would be in the way of the list it is introducing.
///
/// The same material and the same layer as `ShortcutsOverlay`, deliberately: the two are
/// the same kind of thing, and the second one is where this one points.
private struct OnboardingOverlay: View {
    let reduceMotion: Bool
    let dismiss: () -> Void

    @Environment(\.panelTheme) private var theme
    @State private var appeared = false

    private static let points: [(String, String)] = [
        ("↩", "直接粘贴选中的这一条"),
        ("⌘点击", "连续粘贴多条，面板不关"),
        ("?", "随时查看全部快捷键"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("三件事就够用了")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.points, id: \.0) { key, label in
                    // Wide enough for 「⌘点击」, so the three descriptions line up.
                    KeyCap(key: key, label: label, keyWidth: 46)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(key)，\(label)")
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(action: dismiss) {
                    Text("开始使用")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accent))
                        .foregroundStyle(theme.dark ? Color(white: 0.07) : Color.white)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Text("按任意键继续")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The card covers the list and takes every click; VoiceOver has to be told the
        // same thing, or its cursor walks straight past into rows that cannot be
        // reached and are not there.
        .accessibilityAddTraits(.isModal)
        // Opaque, unlike the panel it sits in. Both of these cards are read rather
        // than glanced at, and a colour swatch or a screenshot showing through the
        // text of a shortcut list costs more than the material was buying.
        .background(theme.dark ? Color(white: 0.11) : Color(white: 0.985))
        // The whole layer dismisses, and has to swallow the clicks it does not use — a
        // click that fell through would paste whichever row happened to be underneath.
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .opacity(appeared ? 1 : 0)
        // Faded in rather than simply present: the panel is itself fading and swelling in
        // at this moment, and a card that arrived hard-edged over that would read as two
        // separate things appearing. Under "reduce motion" it is simply there.
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
    }
}

/// Everything the panel answers to, over the list.
///
/// This is now the *only* place the keys are written down: the strip that used to sit
/// under the list repeating three of them is gone, and the `?` glyph in the header is
/// what opens this. It covers the list because that is the only space a panel of fixed
/// size has to give — and because the list is exactly what you stop looking at while you
/// look one of these up.
private struct ShortcutsOverlay: View {
    /// The sheet is the panel's own account of itself, so the one key the settings can
    /// redefine has to be read from the settings rather than written down here.
    let returnPastes: Bool
    /// Whether the screen has room for the preview window at all. On a display too narrow
    /// for the list and its preview side by side there is nothing `→` could open, and a
    /// sheet that listed it would be teaching a key that does nothing.
    let previewAvailable: Bool
    let dismiss: () -> Void

    @Environment(\.panelTheme) private var theme

    /// The key the preview row wears, so the row can be found again to drop it.
    private static let previewKey = "→ ←"

    private var entries: [(String, String)] {
        let first: [(String, String)] = returnPastes
            ? [("↩", "粘贴"), ("⌘↩", "以纯文本粘贴")]
            : [("↩", "复制并关闭"), ("⌘↩", "粘贴")]
        let rest = previewAvailable ? Self.rest : Self.rest.filter { $0.0 != Self.previewKey }
        return first + rest
    }

    private static let rest: [(String, String)] = [
        ("⌥↩", "加入队列"),
        ("⌘1-9", "粘贴第 n 条"),
        ("↑ ↓", "上下移动"),
        ("⇧↑ ⇧↓", "多选"),
        ("PgUp PgDn", "上下翻 10 行"),
        ("Home End", "跳到首行 / 末行"),
        (previewKey, "展开 / 收起预览（图片网格里：左右移动）"),
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
        // The redesign's one genuinely new gesture, and the only one that has nowhere
        // else to announce itself: the sheet is where a rubber band gets discovered.
        ("⌘拖拽", "在图片网格里框选多张"),
        // Both directions on the one line it already had. The sheet is two columns of
        // eleven on a 480pt-tall panel with nothing to scroll in — a row added here is a
        // row off the bottom of the compact panel, so what the 收藏 reorder needs saying
        // is said by its own context menu instead.
        ("拖拽", "拖出面板或拖进来"),
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
                .foregroundStyle(theme.text3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // As with the first-run card: the sheet covers the list, so the list is not
        // somewhere the VoiceOver cursor should be able to wander off to.
        .accessibilityAddTraits(.isModal)
        // Opaque, unlike the panel it sits in. Both of these cards are read rather
        // than glanced at, and a colour swatch or a screenshot showing through the
        // text of a shortcut list costs more than the material was buying.
        .background(theme.dark ? Color(white: 0.11) : Color(white: 0.985))
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
