import AppKit
import Combine
import SwiftUI

enum PanelFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case url
    case image
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "收藏"
        case .text: return "文本"
        case .url: return "链接"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .pinned: return "star"
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }

    var kind: ClipKind? {
        switch self {
        case .all, .pinned: return nil
        case .text: return .text
        case .url: return .url
        case .image: return .image
        case .files: return .files
        }
    }
}

/// A preview's text, and whether it is all of it.
struct PreviewText {
    var body: String
    var truncated: Bool
}

/// State for the panel. Recomputes the visible list whenever the query, the filter or
/// the underlying history changes, and keeps the selection pinned to a sensible row.
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published var filter: PanelFilter = .all { didSet { refresh(resettingSelection: true) } }
    @Published private(set) var results: [ClipRecord] = []
    @Published var selectedIndex = 0
    @Published private(set) var checked: Set<UUID> = []
    @Published private(set) var queueCount = 0

    /// The "now" every relative timestamp in the list is measured against.
    ///
    /// Rows would otherwise keep saying "刚刚" for as long as the panel stays open, which
    /// is wrong within a minute of opening it. Republished on a timer so the subtitles
    /// re-derive themselves; it doubles as the reference date the date grouping uses, so
    /// a row cannot be under 今天 while its subtitle has already moved on.
    @Published private(set) var clockTick = Date()
    private var clockTimer: Timer?

    /// Bumped only when the selection moved by keyboard. The pointer moves it too, and
    /// scrolling for that would pull the hovered row out from under the pointer — which
    /// lands a different row there, which hovers, which scrolls again.
    @Published private(set) var scrollTick = 0

    /// Where the pointer was when the panel opened, and whether it has since moved.
    ///
    /// The panel usually opens directly under the pointer, so on the very first frame
    /// some row is already hovered. Letting that row take the selection would mean ↩
    /// pastes whatever the pointer happened to be resting on rather than the newest
    /// entry, so hovering only starts steering once the pointer has actually moved.
    private var openPointer = NSEvent.mouseLocation
    private var hoverArmed = false

    /// The row the preview window is showing. Sticky: it survives the pointer crossing
    /// the gap between the two windows, so reaching for the preview does not empty it
    /// on the way.
    @Published private(set) var previewIndex: Int?
    @Published private(set) var pointerOnList = false
    @Published private(set) var pointerInPreview = false

    /// The preview is open only while the pointer is on one of the two windows — it is
    /// something you summon by pointing at a row, not a permanent second column.
    var previewOpen: Bool { pointerOnList || pointerInPreview }

    var previewRecord: ClipRecord? {
        guard let previewIndex, results.indices.contains(previewIndex) else { return nil }
        return results[previewIndex]
    }

    /// What the current `results` were matched by, for the highlighting in the rows and
    /// the preview. Deliberately the terms the search *ran with*, not the ones in the
    /// field right now, so a debounced result never highlights a half-typed word.
    @Published private(set) var highlightTerms: [String] = []

    /// Rows whose only hit is past the end of their preview, mapped to a snippet of the
    /// text around it.
    @Published private(set) var contexts: [UUID: String] = [:]

    private unowned let manager: ClipboardManager
    private var observers: [NSObjectProtocol] = []

    private let searchQueue = DispatchQueue(
        label: "com.indincys.hyper.clipboard.panelsearch", qos: .userInitiated
    )
    private var pendingSearch: DispatchWorkItem?
    /// Discards the answer to a query that is no longer the current one; results can
    /// come back out of order once the scan is asynchronous.
    private var searchToken: UInt64 = 0

    init(manager: ClipboardManager) {
        self.manager = manager
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ClipboardManager.historyChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(resettingSelection: false) })
        observers.append(center.addObserver(
            forName: ClipboardManager.queueChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.queueCount = manager.queue.count })
    }

    deinit {
        pendingSearch?.cancel()
        clockTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Runs only while the panel is on screen — there is nothing to keep fresh once it
    /// is gone, and `reset()` re-reads the clock on the way back in anyway.
    func startClock() {
        stopClock()
        clockTick = Date()
        // Scheduled in `.common` rather than through `scheduledTimer`: a menu or a
        // scroll puts the run loop into a tracking mode, and a default-mode timer would
        // simply stop ticking for as long as that lasted.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.clockTick = Date()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    var selected: ClipRecord? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// The rows an action applies to: the ticked ones if there are any, otherwise
    /// just the highlighted row.
    var actionTargets: [ClipRecord] {
        guard !checked.isEmpty else { return selected.map { [$0] } ?? [] }
        // Ordered as displayed, not as ticked, so a merge comes out in list order.
        return results.filter { checked.contains($0.id) }
    }

    /// Typing a word should not run one full-text scan per keystroke. Clearing the
    /// field skips the wait — an empty query is a plain array walk, and anything but an
    /// instant return there reads as the panel having got stuck.
    private func scheduleSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            refresh(resettingSelection: true)
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.refresh(resettingSelection: true) }
        pendingSearch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func refresh(resettingSelection: Bool) {
        let request = ClipSearchRequest(
            terms: ClipSearch.terms(from: query),
            kind: filter.kind,
            pinnedOnly: filter == .pinned
        )
        // Taken here, on the main thread, because the store's state belongs to it.
        // Both halves are copy-on-write, so this is a retain rather than a copy.
        let snapshot = manager.store.searchSnapshot()
        searchToken &+= 1
        let token = searchToken

        // Filtering by kind alone never touches the text, so it stays synchronous and
        // the list is already right by the time the pill finishes animating.
        guard !request.terms.isEmpty else {
            apply(ClipSearch.run(request, in: snapshot), resettingSelection: resettingSelection)
            return
        }

        searchQueue.async { [weak self] in
            let outcome = ClipSearch.run(request, in: snapshot)
            DispatchQueue.main.async {
                guard let self, self.searchToken == token else { return }
                self.apply(outcome, resettingSelection: resettingSelection)
            }
        }
    }

    private func apply(_ outcome: ClipSearchOutcome, resettingSelection: Bool) {
        results = outcome.records
        highlightTerms = outcome.terms
        contexts = outcome.contexts
        checked = checked.intersection(Set(results.map(\.id)))
        queueCount = manager.queue.count
        if resettingSelection {
            selectedIndex = 0
            scrollTick &+= 1
        } else {
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
        }
    }

    func reset() {
        pendingSearch?.cancel()
        pendingSearch = nil
        query = ""
        filter = .all
        checked = []
        selectedIndex = 0
        openPointer = NSEvent.mouseLocation
        hoverArmed = false
        previewIndex = nil
        pointerOnList = false
        pointerInPreview = false
        clockTick = Date()
        refresh(resettingSelection: true)
    }

    // MARK: - Selection

    func move(by delta: Int, extending: Bool) {
        guard !results.isEmpty else { return }
        let previous = selectedIndex
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
        scrollTick &+= 1
        guard extending, selectedIndex != previous else { return }
        checked.insert(results[previous].id)
        checked.insert(results[selectedIndex].id)
    }

    func moveToEdge(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = delta < 0 ? 0 : results.count - 1
        scrollTick &+= 1
    }

    /// The pointer came to rest on a row. Opens the preview on it, and takes the
    /// selection with it — but only once the pointer has really moved since the panel
    /// opened.
    func hover(_ index: Int) {
        guard results.indices.contains(index) else { return }
        previewIndex = index
        pointerOnList = true
        if !hoverArmed {
            let now = NSEvent.mouseLocation
            guard abs(now.x - openPointer.x) > 2 || abs(now.y - openPointer.y) > 2 else { return }
            hoverArmed = true
        }
        selectedIndex = index
    }

    /// The pointer left a row. `previewIndex` deliberately stays put: the controller
    /// closes the preview on a short delay, and the pointer is over neither window
    /// while it crosses the gap towards the preview.
    func hoverEnded(_ index: Int) {
        guard previewIndex == index else { return }
        pointerOnList = false
    }

    func setPointerInPreview(_ inside: Bool) {
        pointerInPreview = inside
    }

    /// A click selects unconditionally — it is a deliberate act, unlike a hover.
    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        hoverArmed = true
        selectedIndex = index
    }

    func toggleChecked(_ id: UUID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func clearChecked() {
        checked.removeAll()
    }

    func cycleFilter(backwards: Bool = false) {
        let all = PanelFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        let next = (index + (backwards ? -1 : 1) + all.count) % all.count
        filter = all[next]
    }

    func thumbnail(for record: ClipRecord) -> NSImage? {
        manager.store.thumbnail(for: record)
    }

    /// Past this the preview is cut short.
    ///
    /// SwiftUI lays out every character of a `Text` before it can draw the first line
    /// of it, and the cost grows faster than the length: measured on this pane, 7,650
    /// characters (a 20 KB entry) took 340ms, 4,000 took 96ms, 2,000 took 28ms and
    /// 1,200 took 13ms. At 340ms on the main thread the panel simply stops responding,
    /// and it was paying that on every selection change.
    ///
    /// 2,000 characters is about two screenfuls here — more than enough to recognise an
    /// entry by, which is all a preview owes anyone.
    private static let previewCharacterCap = 2_000

    private static let previewQueue = DispatchQueue(
        label: "com.indincys.hyper.clip.preview", qos: .userInitiated
    )

    /// Reads an entry's text off the main thread and returns at most `previewCharacterCap`
    /// characters of it.
    func previewText(for record: ClipRecord) async -> PreviewText? {
        guard record.kind != .image, !record.oversized else { return nil }
        // Only the file's location crosses over — none of the store's state is safe to
        // touch away from the main thread.
        let location = manager.store.payloadLocation(for: record.id)
        let isFiles = record.kind == .files
        let fallback = record.preview

        return await withCheckedContinuation { continuation in
            Self.previewQueue.async {
                guard let data = try? Data(contentsOf: location),
                      let payload = ClipPayloadCoder.decode(data) else {
                    continuation.resume(returning: nil)
                    return
                }
                let full: String
                if isFiles {
                    full = ClipCapture.fileURLs(from: payload).map(\.path).joined(separator: "\n")
                } else {
                    // Plain-text types only. The styled-text fallbacks in
                    // `plainText(from:)` go through NSAttributedString, whose HTML
                    // importer is main-thread-only and slow enough to stall the panel
                    // on its own; the stored preview line stands in for those.
                    full = ClipCapture.plainTextOnly(from: payload) ?? fallback
                }
                let capped = full.count > Self.previewCharacterCap
                continuation.resume(returning: PreviewText(
                    body: capped ? String(full.prefix(Self.previewCharacterCap)) : full,
                    truncated: capped
                ))
            }
        }
    }

    func isQueued(_ id: UUID) -> Bool {
        manager.queue.ids.contains(id)
    }

    /// For the preview's per-format copy buttons. Routed through the manager so the
    /// write lands on the monitor's ignore list rather than in the history.
    func copyPlainString(_ string: String) {
        manager.copyPlainString(string)
    }
}

/// Borderless, non-activating, and still able to take key focus — the combination a
/// launcher-style panel needs. Without `canBecomeKey` a borderless window can never
/// receive typing; without `.nonactivatingPanel` showing it would yank the whole
/// application forward and complicate getting focus back to where the paste has to go.
final class ClipboardPanel: NSPanel {
    /// Cleared while a paste needs the keyboard to reach the target application. A
    /// window that is still allowed to become key simply takes it straight back.
    var acceptsKey = true

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// The preview sits in a window of its own so it can extend past the list's edge
/// instead of permanently eating half of it. It must never take focus, or it would
/// pull the keyboard away from the search field the moment it appeared.
final class ClipboardPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that acts on the click that reaches it.
///
/// The panel deliberately floats over an application that stays active, so *every*
/// click into it is a "first mouse" click — and AppKit's default is to spend that
/// click on bringing the window forward and discard it. `NSHostingView` inherits that
/// default, which is why an untouched panel ignores the first click on any row and
/// only the keyboard appears to work.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class ClipboardPanelController {
    private unowned let manager: ClipboardManager
    private let model: ClipboardPanelModel

    private var panel: ClipboardPanel?
    private var previewPanel: ClipboardPreviewPanel?
    /// Where the preview goes, or nil when the screen has no room for it.
    private var previewFrame: NSRect?
    private var previewHideWork: DispatchWorkItem?
    /// Whether the panel is meant to be up. `panel.isVisible` cannot answer that: it
    /// stays true through the closing fade, so a `syncPreview` that arrives in those
    /// few frames would put the preview back and leave it stranded on screen after the
    /// list has gone.
    private var isOpen = false
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Modifiers carried by the most recent click into the panel.
    private var clickModifiers: NSEvent.ModifierFlags = []
    /// Set while a paste deliberately hands the keyboard to the target application and
    /// means to keep the panel up regardless.
    private var suppressResignHide = false
    private var keyRestoreWork: DispatchWorkItem?

    /// Whoever was in front when the panel opened — the application a paste has to go
    /// back to. Captured before the panel appears, because afterwards it is too late.
    private var previousApp: NSRunningApplication?

    init(manager: ClipboardManager) {
        self.manager = manager
        self.model = ClipboardPanelModel(manager: manager)

        // The preview follows the selection, which anything from a keystroke to a
        // hover to a history change can move. Rather than remember to poke it from
        // each of those, it re-derives itself whenever the model reports a change.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncPreview() }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Show / hide

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        isOpen = true

        let panel = existingPanel()
        model.reset()
        position(panel)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            panel.animator().alphaValue = 1
        }

        installKeyMonitor()
        observeResign(panel)
        model.startClock()
        syncPreview()
    }

    /// `animated: false` takes the panel off screen synchronously.
    ///
    /// That matters for anything that follows the hide with a synthetic keystroke. A
    /// non-activating panel does not activate the application, but while it is on
    /// screen it *does* hold the system keyboard focus — that is the whole point of
    /// the style. A ⌘V posted during the fade is therefore delivered to the panel's
    /// own search field, never to the target application, and nothing downstream can
    /// detect it: `NSWorkspace.frontmostApplication` names the target throughout,
    /// because a non-activating panel never changed it in the first place.
    func hide(animated: Bool = true) {
        isOpen = false
        keyRestoreWork?.cancel()
        keyRestoreWork = nil
        suppressResignHide = false
        clickModifiers = []
        panel?.acceptsKey = true
        model.stopClock()
        removeKeyMonitor()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        // Straight out, never faded: a preview lingering beside a panel that is already
        // gone reads as a stray window rather than as part of the same thing.
        previewHideWork?.cancel()
        previewHideWork = nil
        previewPanel?.orderOut(nil)
        guard let panel, panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
    }

    private func existingPanel() -> ClipboardPanel {
        if let panel { return panel }

        let panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        decorate(panel)
        // Dragging the list would leave the preview behind, and a launcher that is
        // dismissed on the next click has nothing to gain from being movable.
        panel.isMovableByWindowBackground = false
        panel.contentView = chrome(ClipboardPanelView(model: model, actions: makeActions()))
        self.panel = panel
        return panel
    }

    private func existingPreviewPanel() -> ClipboardPreviewPanel {
        if let previewPanel { return previewPanel }

        let panel = ClipboardPreviewPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        decorate(panel)
        // Left interactive on purpose: a long entry's preview scrolls, and its text is
        // selectable. Clicking it cannot dismiss the list, because this panel never
        // becomes key and so the list never resigns.
        panel.contentView = chrome(ClipboardPreviewView(model: model))
        previewPanel = panel
        return panel
    }

    private func decorate(_ panel: NSPanel) {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// The blurred, rounded backdrop both windows share, wrapped around a SwiftUI root.
    private func chrome<Content: View>(_ content: Content) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        let hosting = PanelHostingView(rootView: content)
        // Without this the hosting view publishes SwiftUI's fitting size as its
        // intrinsic size, and because it is pinned to the content view those become
        // required constraints on the window: a long history then stretches the panel
        // to the height of the whole list instead of scrolling inside it. The windows
        // size themselves in `position(_:)`; the content has to live within that.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// Sizes are fixed rather than content-driven: a launcher that changes shape as you
    /// type is hard to aim at, and one row of history should not produce a different
    /// window than a thousand. Only a screen too small to hold them shrinks them.
    /// Both windows are the same shape — the preview reads as the list's other half
    /// rather than as a different kind of thing.
    private static let windowSize = NSSize(width: 400, height: 576)
    private static let windowGap: CGFloat = 10

    /// Opens on whichever screen the pointer is on, a little above centre so the list
    /// sits where the eye already is rather than at the very middle.
    ///
    /// Only the list is centred. The preview is the exception rather than the rule now
    /// that it takes a hover to summon, so centring the pair would leave the list
    /// permanently off to one side for the sake of a window that is usually absent.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = NSSize(
            width: min(Self.windowSize.width, visible.width - 40),
            height: min(Self.windowSize.height, visible.height - 40)
        )
        let x = (visible.midX - size.width / 2).rounded()
        let y = (visible.midY - size.height / 2 + visible.height * 0.08).rounded()
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)

        // To the right by preference, to the left if that is where the room is.
        let toRight = x + size.width + Self.windowGap
        let toLeft = x - Self.windowGap - size.width
        if toRight + size.width <= visible.maxX - 12 {
            previewFrame = NSRect(x: toRight, y: y, width: size.width, height: size.height)
        } else if toLeft >= visible.minX + 12 {
            previewFrame = NSRect(x: toLeft, y: y, width: size.width, height: size.height)
        } else {
            previewFrame = nil
        }
    }

    /// Brings the preview up while the pointer is on either window, and takes it away
    /// shortly after the pointer leaves both.
    private func syncPreview() {
        let wanted = isOpen && model.previewOpen
            && model.previewRecord != nil && previewFrame != nil

        guard wanted else {
            // Closing is deferred: reaching for the preview means crossing the gap
            // between the windows, and for those few frames the pointer is on neither.
            guard previewPanel?.isVisible == true, previewHideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.previewHideWork = nil
                guard let self, !(self.isOpen && self.model.previewOpen) else { return }
                self.previewPanel?.orderOut(nil)
            }
            previewHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return
        }

        previewHideWork?.cancel()
        previewHideWork = nil

        guard let panel, let previewFrame else { return }
        let preview = existingPreviewPanel()
        guard !preview.isVisible else { return }
        preview.setFrame(previewFrame, display: false)
        preview.alphaValue = 0
        preview.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            preview.animator().alphaValue = 1
        }
        // Ordering the preview up must not cost the list its keyboard focus.
        panel.makeKeyAndOrderFront(nil)
    }

    private func observeResign(_ panel: NSPanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Clicking anywhere else means the user is done with the panel — unless the
            // panel itself just handed the keyboard over so a paste could land.
            guard let self, !self.suppressResignHide else { return }
            self.hide()
        }
    }

    // MARK: - Actions

    private func makeActions() -> ClipboardPanelActions {
        ClipboardPanelActions(
            paste: { [weak self] plainText in self?.paste(plainTextOnly: plainText) },
            pasteKeepingOpen: { [weak self] in self?.paste(plainTextOnly: false, keepingPanelOpen: true) },
            copyOnly: { [weak self] in self?.copyOnly() },
            enqueue: { [weak self] in self?.enqueue() },
            delete: { [weak self] in self?.deleteSelected() },
            togglePin: { [weak self] in self?.togglePin() },
            clearQueue: { [weak self] in
                self?.manager.clearQueue()
                ClipboardHUD.shared.show("队列已清空", symbol: "trash")
            },
            toggleChecked: { [weak self] id in self?.model.toggleChecked(id) },
            selectIndex: { [weak self] index in self?.model.select(index) },
            activateRow: { [weak self] index in self?.activateRow(index) },
            hoverIndex: { [weak self] index in self?.model.hover(index) },
            hoverEnded: { [weak self] index in self?.model.hoverEnded(index) },
            close: { [weak self] in self?.hide() }
        )
    }

    /// A click landed on a row. What it does depends on the modifiers held at the time:
    /// ⌘ pastes and leaves the panel up so the next one can follow, ⌥ ticks the row for
    /// a merged paste, and a plain click pastes and closes.
    private func activateRow(_ index: Int) {
        model.select(index)
        let flags = modifiersHeld()
        // Consumed, so a click whose flags never arrived cannot inherit the last one's.
        // Falling back to "no modifiers" costs at most a panel that closes when it could
        // have stayed; inheriting a stale ⌘ would leave it open when it should close.
        clickModifiers = []
        if flags.contains(.command) {
            paste(plainTextOnly: false, keepingPanelOpen: true)
        } else if flags.contains(.option) {
            guard model.results.indices.contains(index) else { return }
            model.toggleChecked(model.results[index].id)
        } else {
            paste(plainTextOnly: false)
        }
    }

    /// The modifiers on the click currently being handled.
    ///
    /// Deliberately not `NSEvent.modifierFlags`. While the panel is up the application
    /// is active but *not* frontmost — the menu bar still belongs to the application
    /// behind — so the window server delivers modifier-key events there and they never
    /// reach us, leaving that global permanently stale. That is why ⌘ appeared to go to
    /// the application behind the panel.
    ///
    /// Not `CGEventSource.flagsState` either, tempting as a focus-independent read is:
    /// `Paster.sendPaste` synthesizes ⌘V without a matching modifier release, so the
    /// session state latches "command held" afterwards and every later plain click
    /// reads as a ⌘-click. The event's own flags are stamped by the window server when
    /// the click happens, owe nothing to focus, and cannot be poisoned that way.
    private func modifiersHeld() -> NSEvent.ModifierFlags { clickModifiers }

    private func paste(plainTextOnly: Bool, keepingPanelOpen: Bool = false) {
        guard !keepingPanelOpen else {
            pasteKeepingPanelOpen(plainTextOnly: plainTextOnly)
            return
        }
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        let app = previousApp
        let merged = targets.count > 1
        // Synchronously, not faded — see `hide(animated:)`. The keystroke cannot go
        // out while the panel still owns the keyboard.
        hide(animated: false)
        // A beat for the window server to hand the focus back to the target
        // application before the keystroke goes out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.manager.paste(
                records: targets, merged: merged, plainTextOnly: plainTextOnly, activating: app
            )
        }
    }

    /// Pastes and leaves the panel where it is, so several entries can be sent one after
    /// another without reopening it.
    ///
    /// The hard part is that the panel has to genuinely hand the keyboard over first.
    /// The ordinary paste gets that for free by taking the panel off screen; this one
    /// cannot, so it asks and then *waits to be sure*. Asking alone is not enough:
    ///
    ///   * `withApplicationFrontmost` is no help here. It waits on
    ///     `NSWorkspace.frontmostApplication`, which names the target application the
    ///     entire time the panel holds the keyboard — so it sees nothing to wait for and
    ///     fires the keystroke almost immediately.
    ///   * A panel that may still become key takes the focus straight back, which is why
    ///     `acceptsKey` is cleared for the duration.
    ///
    /// Send the ⌘V too early and it lands on the panel instead, where nothing handles it
    /// — that is the beep, and the paste that never arrives.
    private func pasteKeepingPanelOpen(plainTextOnly: Bool) {
        let targets = model.actionTargets
        guard !targets.isEmpty, let panel else { return }
        let merged = targets.count > 1
        let app = previousApp

        keyRestoreWork?.cancel()
        keyRestoreWork = nil
        suppressResignHide = true

        panel.acceptsKey = false
        NSApp.deactivate()
        app?.activate(options: [])

        whenKeyboardReleased { [weak self] released in
            guard let self else { return }
            // If it never let go, fall back to what always works: off screen for the
            // keystroke, and straight back afterwards.
            if !released { panel.orderOut(nil) }
            self.manager.paste(
                records: targets, merged: merged, plainTextOnly: plainTextOnly, activating: app
            )
            self.model.clearChecked()
            self.scheduleKeyRestore(reshowing: !released)
        }
    }

    /// Polls briefly for the panel to stop being the key window. Focus changes are
    /// asynchronous, and the one notification that would report this — `didResignKey` —
    /// is exactly what this path suppresses.
    private func whenKeyboardReleased(_ body: @escaping (Bool) -> Void) {
        var attempts = 0
        func check() {
            guard let panel else { return body(false) }
            if !panel.isKeyWindow { return body(true) }
            attempts += 1
            guard attempts < 15 else { return body(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
        }
        check()
    }

    /// Takes the keyboard back once the paste has landed, so Escape and the search field
    /// work again — and so clicking away closes the panel as it should.
    private func scheduleKeyRestore(reshowing: Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.keyRestoreWork = nil
            self.suppressResignHide = false
            guard self.isOpen, let panel = self.panel else { return }
            panel.acceptsKey = true
            if reshowing { panel.orderFrontRegardless() }
            panel.makeKeyAndOrderFront(nil)
        }
        keyRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func copyOnly() {
        guard let record = model.selected else { return }
        manager.copyToClipboard(record, plainTextOnly: false)
        hide()
    }

    private func enqueue() {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        manager.enqueue(targets.map(\.id))
        model.clearChecked()
        ClipboardHUD.shared.show("已加入队列 · 共 \(manager.queue.count) 条", symbol: "text.append")
    }

    private func deleteSelected() {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        for record in targets { manager.delete(record.id) }
        model.clearChecked()
    }

    private func togglePin() {
        guard let record = model.selected else { return }
        manager.togglePin(record.id)
    }

    // MARK: - Keyboard

    /// Arrow keys and Return have to be intercepted before the search field sees them,
    /// which a local monitor does and a SwiftUI `.onKeyPress` on a focused text field
    /// does not do reliably.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
        // The window server stamps every mouse event with the modifiers held at the
        // time, which is the only account of them the panel can rely on — see
        // `modifiersHeld()`. Recorded here, before the event reaches SwiftUI, because a
        // tap gesture does not carry the event that triggered it.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            self?.clickModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        switch event.keyCode {
        case 126:  // up
            if command { model.moveToEdge(-1) } else { model.move(by: -1, extending: shift) }
            return true
        case 125:  // down
            if command { model.moveToEdge(1) } else { model.move(by: 1, extending: shift) }
            return true
        case 36, 76:  // return, keypad enter
            if option { enqueue() } else { paste(plainTextOnly: command) }
            return true
        case 53:  // escape
            if !model.query.isEmpty {
                model.query = ""
            } else if !model.checked.isEmpty {
                model.clearChecked()
            } else {
                hide()
            }
            return true
        case 48:  // tab
            model.cycleFilter(backwards: shift)
            return true
        case 51 where command:  // ⌘⌫
            deleteSelected()
            return true
        case 35 where command:  // ⌘P
            togglePin()
            return true
        case 8 where command:  // ⌘C
            copyOnly()
            return true
        case 40 where command && shift:  // ⌘⇧K
            manager.clearQueue()
            ClipboardHUD.shared.show("队列已清空", symbol: "trash")
            return true
        default:
            break
        }

        // ⌘1 … ⌘9 — straight to the nth row, the fastest path for a known position.
        if command, let characters = event.charactersIgnoringModifiers,
           let digit = Int(characters), (1...9).contains(digit) {
            let index = digit - 1
            guard model.results.indices.contains(index) else { return true }
            model.clearChecked()
            model.select(index)
            paste(plainTextOnly: false)
            return true
        }

        return false
    }
}

/// Callbacks the SwiftUI layer needs. A plain struct of closures keeps the view free
/// of any reference to AppKit plumbing.
struct ClipboardPanelActions {
    var paste: (Bool) -> Void
    var pasteKeepingOpen: () -> Void
    var copyOnly: () -> Void
    var enqueue: () -> Void
    var delete: () -> Void
    var togglePin: () -> Void
    var clearQueue: () -> Void
    var toggleChecked: (UUID) -> Void
    var selectIndex: (Int) -> Void
    var activateRow: (Int) -> Void
    var hoverIndex: (Int) -> Void
    var hoverEnded: (Int) -> Void
    var close: () -> Void
}
