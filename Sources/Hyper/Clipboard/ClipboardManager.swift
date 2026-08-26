import AppKit
import Foundation
import os

/// Owns the clipboard feature: the history store, the change monitor, the batch queue
/// and the panel. `AppDelegate` starts it; `HyperTap` calls `perform(_:)` when a
/// binding resolves to a built-in action.
final class ClipboardManager {
    static let shared = ClipboardManager()

    static let historyChanged = Notification.Name("com.indincys.hyper.clipboard.historyChanged")
    static let queueChanged = Notification.Name("com.indincys.hyper.clipboard.queueChanged")

    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard")

    let store = ClipStore()
    let queue = PasteQueue()
    private let monitor = ClipboardMonitor()
    private lazy var panel = ClipboardPanelController(manager: self)

    private(set) var settings = ClipboardSettings()
    private var started = false

    /// Retention used to be enforced every time the panel opened, which put an O(n)
    /// walk on the one path that has to feel instant. `insert` already sweeps after
    /// every capture, so the only case left uncovered is a machine left running for
    /// days without a single copy — hence a slow timer rather than anything eager.
    private var sweepTimer: Timer?
    private let sweepInterval: TimeInterval = 3600

    private init() {
        monitor.onChange = { [weak self] in self?.captureFromPasteboard() }
        // The full-text index arrives a moment after launch. If the panel happens to be
        // open with a query in it, the same query now has more to match against.
        store.onSearchIndexLoaded = {
            NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        // Capture starts straight away — the history is read from disk in the
        // background, and a copy made during those first milliseconds is merged in
        // rather than lost.
        monitor.acceptCurrentAsSeen()
        monitor.start()
        observeSystem()
        startSweepTimer()

        // Everything below reads `store.records`, so it has to wait for the load.
        // `reconcileOrphans` especially: run against an empty array it would delete
        // every payload file on disk.
        queue.restore()
        store.whenLoaded { [weak self] in
            guard let self else { return }
            self.store.sweep()
            self.store.reconcileOrphans()
            self.queue.prune(against: Set(self.store.records.map(\.id)))
            NotificationCenter.default.post(name: Self.historyChanged, object: nil)
            NotificationCenter.default.post(name: Self.queueChanged, object: nil)
        }
        log.info("clipboard feature started")
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.stop()
        sweepTimer?.invalidate()
        sweepTimer = nil
        panel.hide()
        store.flushNow()
        queue.flushNow()
        log.info("clipboard feature stopped")
    }

    func applicationWillTerminate() {
        store.flushNow()
        queue.flushNow()
    }

    private func startSweepTimer() {
        guard sweepTimer == nil else { return }
        let timer = Timer(timeInterval: sweepInterval, repeats: true) { [weak self] _ in
            self?.sweepNow()
        }
        // Generous tolerance: nothing depends on this landing at a particular moment,
        // and the slack lets the system coalesce the wake-up with other timers.
        timer.tolerance = sweepInterval / 6
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    private func sweepNow() {
        let before = store.records.count
        store.sweep()
        guard store.records.count != before else { return }
        // Eviction can take rows out from under an open panel and leave the queue
        // pointing at records that no longer exist.
        queue.prune(against: Set(store.records.map(\.id)))
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    func apply(_ settings: ClipboardSettings) {
        self.settings = settings
        store.retentionDays = settings.retentionDays
        store.maxItems = settings.maxItems
        if settings.enabled {
            start()
            // Retention may just have been tightened, so re-apply it — but not before
            // the history is in memory, or there would be nothing to apply it to.
            store.whenLoaded { [weak self] in self?.sweepNow() }
        } else {
            stop()
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.monitor.suspend() }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.monitor.resume() }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.monitor.suspend() }
        distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.monitor.resume() }
    }

    /// Called by the event tap the instant it sees a copy keystroke. This is the fast
    /// path: it makes the common case event-driven and lets the backstop timer run
    /// slower than a poll-only design could get away with.
    func copyKeystrokeObserved() {
        guard started, settings.enabled else { return }
        monitor.checkSoon()
    }

    // MARK: - Capture

    private var captureOptions: ClipCapture.Options {
        ClipCapture.Options(
            recordImages: settings.recordImages,
            skipConcealed: settings.skipConcealed,
            skipTransient: settings.skipTransient,
            maxItemBytes: settings.maxItemBytes
        )
    }

    @discardableResult
    private func captureFromPasteboard() -> ClipRecord? {
        guard settings.enabled else { return nil }

        switch ClipCapture.read(NSPasteboard.general, options: captureOptions) {
        case .ignored(let reason):
            // Info, not debug. "I copied something and it did not show up" is the
            // question this feature will actually be asked, and os_log's debug level
            // is memory-only — by the time anyone reads the log it is already gone.
            log.info("clipboard change ignored: \(reason, privacy: .public)")
            return nil

        case .captured(let payload, let kind, let reduction):
            // The frontmost application at the moment of the change is, for all
            // practical purposes, whoever did the copying.
            let source = NSWorkspace.shared.frontmostApplication
            let record = store.insert(
                ClipStore.Insertion(
                    payload: payload,
                    kind: kind,
                    oversized: reduction.oversized,
                    byteSize: reduction.byteSize,
                    sourceBundleID: source?.bundleIdentifier,
                    sourceName: source?.localizedName
                )
            )
            if reduction.oversized {
                log.info("entry over the size cap; kept metadata only (\(reduction.byteSize) bytes)")
            }
            NotificationCenter.default.post(name: Self.historyChanged, object: nil)
            return record
        }
    }

    // MARK: - Actions

    func perform(_ action: BuiltinAction) {
        guard settings.enabled else {
            ClipboardHUD.shared.show("剪贴板功能已关闭", symbol: "clipboard")
            return
        }
        switch action {
        case .clipboardPanel: togglePanel()
        case .clipEnqueue: collectIntoQueue()
        case .clipPasteNext: pasteNext()
        }
    }

    func togglePanel() {
        if panel.isVisible {
            panel.hide()
            return
        }

        // Close the polling blind window before the panel reads the store. The backstop
        // timer runs at 1.5s, so something copied from the Edit menu or a right-click —
        // neither of which produces a keystroke for the tap to see — can still be
        // unrecorded at the moment the panel opens, and the entry the user is reaching
        // for is missing from the very list they opened to find it in. `check()` is one
        // Mach round trip for an integer, and the capture it triggers is synchronous,
        // so by the time `show()` runs the entry is already at the top.
        monitor.check()

        // Deliberately no sweep here: retention is enforced after every capture and by
        // the hourly timer, and this is the one path where an O(n) walk plus a round of
        // file deletions would be paid for with visible latency.
        panel.show()
    }

    /// `Hyper + Q`: copy whatever is selected in the frontmost application and append
    /// it to the batch queue, without disturbing the ordinary clipboard workflow.
    ///
    /// Deferred until the hyper key is released — a ⌘C synthesized while ⌘⌃⌥⇧ are
    /// still latched arrives as ⌘⌃⌥⇧C and copies nothing.
    private func collectIntoQueue() {
        HyperTap.shared.runAfterHyperRelease { [weak self] in
            guard let self else { return }
            Paster.sendCopy()
            // The copy is asynchronous and has no completion to hook, so watch the
            // change count for it rather than guessing at a delay.
            self.monitor.waitForChange(timeout: 0.6) { changed in
                guard changed else {
                    ClipboardHUD.shared.show("没有可复制的内容", symbol: "exclamationmark.triangle")
                    return
                }
                guard let record = self.captureFromPasteboard() else {
                    ClipboardHUD.shared.show("这条内容没有被记录", symbol: "eye.slash")
                    return
                }
                // We already recorded this change; stop the monitor recording it again.
                self.monitor.acceptCurrentAsSeen()
                self.queue.enqueue(record.id)
                NotificationCenter.default.post(name: Self.queueChanged, object: nil)
                ClipboardHUD.shared.show(
                    "已加入队列 · 第 \(self.queue.count) 条", symbol: "text.append"
                )
            }
        }
    }

    /// `Hyper + V`: dispense the next queued entry. With an empty queue it pastes the
    /// most recent history entry, so the binding is never a dead key.
    private func pasteNext() {
        let fromQueue = queue.dequeue()
        guard let id = fromQueue ?? store.records.first?.id,
              let record = store.record(id: id) else {
            ClipboardHUD.shared.show("剪贴板历史是空的", symbol: "clipboard")
            return
        }

        if fromQueue != nil {
            NotificationCenter.default.post(name: Self.queueChanged, object: nil)
        }

        HyperTap.shared.runAfterHyperRelease { [weak self] in
            guard let self else { return }
            self.paste(records: [record], merged: false, plainTextOnly: false, activating: nil)
            if let remaining = fromQueue == nil ? nil : self.queue.count, remaining > 0 {
                ClipboardHUD.shared.show("队列还剩 \(remaining) 条", symbol: "text.append", duration: 0.9)
            }
        }
    }

    // MARK: - Pasting

    /// The single path everything pastes through: place on the pasteboard, make sure
    /// the target application is frontmost, synthesize ⌘V, optionally put the previous
    /// clipboard back.
    func paste(
        records: [ClipRecord],
        merged: Bool,
        plainTextOnly: Bool,
        activating app: NSRunningApplication?
    ) {
        guard !records.isEmpty else { return }

        let payloads = records.compactMap { record -> ClipPayload? in
            guard !record.oversized else { return nil }
            return store.payload(for: record.id)
        }
        guard !payloads.isEmpty else {
            ClipboardHUD.shared.show("这条内容太大，当时没有保存", symbol: "exclamationmark.triangle")
            return
        }

        let previous = settings.restoreAfterPaste ? Paster.snapshot() : nil

        let changeCount: Int
        if merged, payloads.count > 1 {
            changeCount = Paster.placeMerged(payloads, separator: settings.joinSeparator)
        } else {
            changeCount = Paster.place(payloads[0], plainTextOnly: plainTextOnly)
        }
        monitor.ignore(changeCount: changeCount)

        Paster.withApplicationFrontmost(app) { [weak self] in
            Paster.sendPaste()
            guard let self, let previous else { return }
            // Long enough for the target application to have read the pasteboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let restored = Paster.place(previous, plainTextOnly: false)
                self.monitor.ignore(changeCount: restored)
            }
        }
    }

    /// Puts an entry on the clipboard without pasting it.
    func copyToClipboard(_ record: ClipRecord, plainTextOnly: Bool) {
        guard let payload = store.payload(for: record.id) else { return }
        let changeCount = Paster.place(payload, plainTextOnly: plainTextOnly)
        monitor.ignore(changeCount: changeCount)
        ClipboardHUD.shared.show("已复制", symbol: "doc.on.doc")
    }

    // MARK: - Queue, from the panel

    func enqueue(_ ids: [UUID]) {
        queue.enqueue(contentsOf: ids)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    func clearQueue() {
        queue.clear()
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    func delete(_ id: UUID) {
        store.delete(id)
        queue.remove(id)
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    func togglePin(_ id: UUID) {
        store.togglePin(id)
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
    }

    func clearHistory(includingPinned: Bool) {
        if includingPinned { store.clearAll() } else { store.clearUnpinned() }
        queue.prune(against: Set(store.records.map(\.id)))
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }
}
