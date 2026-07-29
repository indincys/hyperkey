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

/// State for the panel. Recomputes the visible list whenever the query, the filter or
/// the underlying history changes, and keeps the selection pinned to a sensible row.
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" { didSet { refresh(resettingSelection: true) } }
    @Published var filter: PanelFilter = .all { didSet { refresh(resettingSelection: true) } }
    @Published private(set) var results: [ClipRecord] = []
    @Published var selectedIndex = 0
    @Published private(set) var checked: Set<UUID> = []
    @Published private(set) var queueCount = 0

    private unowned let manager: ClipboardManager
    private var observers: [NSObjectProtocol] = []

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
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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

    func refresh(resettingSelection: Bool) {
        results = manager.store.search(
            query, kind: filter.kind, pinnedOnly: filter == .pinned
        )
        checked = checked.intersection(Set(results.map(\.id)))
        queueCount = manager.queue.count
        if resettingSelection {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
        }
    }

    func reset() {
        query = ""
        filter = .all
        checked = []
        selectedIndex = 0
        refresh(resettingSelection: true)
    }

    // MARK: - Selection

    func move(by delta: Int, extending: Bool) {
        guard !results.isEmpty else { return }
        let previous = selectedIndex
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
        guard extending, selectedIndex != previous else { return }
        checked.insert(results[previous].id)
        checked.insert(results[selectedIndex].id)
    }

    func moveToEdge(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = delta < 0 ? 0 : results.count - 1
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

    func fullText(for record: ClipRecord) -> String? {
        guard let payload = manager.store.payload(for: record.id) else { return nil }
        if record.kind == .files {
            return ClipCapture.fileURLs(from: payload).map(\.path).joined(separator: "\n")
        }
        return ClipCapture.plainText(from: payload)
    }

    func isQueued(_ id: UUID) -> Bool {
        manager.queue.ids.contains(id)
    }
}

/// Borderless, non-activating, and still able to take key focus — the combination a
/// launcher-style panel needs. Without `canBecomeKey` a borderless window can never
/// receive typing; without `.nonactivatingPanel` showing it would yank the whole
/// application forward and complicate getting focus back to where the paste has to go.
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ClipboardPanelController {
    private unowned let manager: ClipboardManager
    private let model: ClipboardPanelModel

    private var panel: ClipboardPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Whoever was in front when the panel opened — the application a paste has to go
    /// back to. Captured before the panel appears, because afterwards it is too late.
    private var previousApp: NSRunningApplication?

    init(manager: ClipboardManager) {
        self.manager = manager
        self.model = ClipboardPanelModel(manager: manager)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Show / hide

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication

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
    }

    func hide() {
        removeKeyMonitor()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func existingPanel() -> ClipboardPanel {
        if let panel { return panel }

        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

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

        let hosting = NSHostingView(
            rootView: ClipboardPanelView(model: model, actions: makeActions())
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        self.panel = panel
        return panel
    }

    /// Opens on whichever screen the pointer is on, a little above centre so the list
    /// sits where the eye already is rather than at the very middle.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.midY - size.height / 2 + visible.height * 0.08).rounded()
            )
        )
    }

    private func observeResign(_ panel: NSPanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Clicking anywhere else means the user is done with the panel.
            self?.hide()
        }
    }

    // MARK: - Actions

    private func makeActions() -> ClipboardPanelActions {
        ClipboardPanelActions(
            paste: { [weak self] plainText in self?.paste(plainTextOnly: plainText) },
            copyOnly: { [weak self] in self?.copyOnly() },
            enqueue: { [weak self] in self?.enqueue() },
            delete: { [weak self] in self?.deleteSelected() },
            togglePin: { [weak self] in self?.togglePin() },
            clearQueue: { [weak self] in
                self?.manager.clearQueue()
                ClipboardHUD.shared.show("队列已清空", symbol: "trash")
            },
            toggleChecked: { [weak self] id in self?.model.toggleChecked(id) },
            selectIndex: { [weak self] index in self?.model.selectedIndex = index },
            close: { [weak self] in self?.hide() }
        )
    }

    private func paste(plainTextOnly: Bool) {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        let app = previousApp
        let merged = targets.count > 1
        hide()
        // One turn of the run loop so the panel is actually off screen and focus has
        // settled before the keystroke goes out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.manager.paste(
                records: targets, merged: merged, plainTextOnly: plainTextOnly, activating: app
            )
        }
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
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
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
            model.selectedIndex = index
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
    var copyOnly: () -> Void
    var enqueue: () -> Void
    var delete: () -> Void
    var togglePin: () -> Void
    var clearQueue: () -> Void
    var toggleChecked: (UUID) -> Void
    var selectIndex: (Int) -> Void
    var close: () -> Void
}
