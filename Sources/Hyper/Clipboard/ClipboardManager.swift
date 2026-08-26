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
        // Retention evicts on its own, from inside `insert` as well as from the timer, so
        // the queue has to be told: it holds ids, and one whose record has been swept away
        // makes the menu bar count a lie and `Hyper + V` a dead key.
        store.onEvicted = { [weak self] ids in
            guard let self else { return }
            let before = self.queue.count
            for id in ids { self.queue.remove(id) }
            guard self.queue.count != before else { return }
            NotificationCenter.default.post(name: Self.queueChanged, object: nil)
        }
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
        // Eviction can take rows out from under an open panel; the queue side of it is
        // handled by `store.onEvicted`, which covers the sweeps this method never sees.
        store.sweep()
        guard store.records.count != before else { return }
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

        // The frontmost application at the moment of the change is, for all practical
        // purposes, whoever did the copying. Resolved before the pasteboard is read so
        // an excluded application's secret is never even pulled into memory here.
        let source = NSWorkspace.shared.frontmostApplication
        if let bundleID = source?.bundleIdentifier, settings.ignoredApps.contains(bundleID) {
            log.info("clipboard change ignored: source app excluded")
            return nil
        }

        switch ClipCapture.read(NSPasteboard.general, options: captureOptions) {
        case .ignored(let reason):
            // Info, not debug. "I copied something and it did not show up" is the
            // question this feature will actually be asked, and os_log's debug level
            // is memory-only — by the time anyone reads the log it is already gone.
            log.info("clipboard change ignored: \(reason, privacy: .public)")
            return nil

        case .captured(let payload, let kind, let reduction):
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

    /// Records something dragged onto the panel from another application.
    ///
    /// Down the same road a copy takes, deliberately: `insert` derives the preview, the
    /// thumbnail, the search text and the content tag from the payload, so a dropped entry
    /// is an ordinary row in every respect except the source it names. The size cap is
    /// applied here rather than inside the store, because the cap is a setting and the
    /// store does not read settings — this is what `ClipCapture.read` does for a copy.
    @discardableResult
    func saveDropped(payload: ClipPayload, kind: ClipKind) -> ClipRecord? {
        guard settings.enabled, !payload.isEmpty else { return nil }
        guard kind != .image || settings.recordImages else {
            ClipboardHUD.shared.show(
                "设置里关掉了「记录图片」", symbol: "photo", style: .warning
            )
            return nil
        }

        let byteSize = ClipPayloadCoder.byteSize(payload)
        let oversized = byteSize > settings.maxItemBytes
        let record = store.insert(
            ClipStore.Insertion(
                payload: payload,
                kind: kind,
                oversized: oversized,
                byteSize: byteSize,
                sourceBundleID: nil,
                sourceName: ClipDropIntake.sourceName
            )
        )
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)

        guard !oversized else {
            ClipboardHUD.shared.show(
                "这条内容超过了单条上限", detail: record.preview,
                symbol: "exclamationmark.triangle", style: .warning
            )
            return record
        }
        // The list is still open behind the HUD and the new row is at the top of it, so
        // this is a confirmation rather than the only account of what happened — but a
        // drop lands with the pointer somewhere in the middle of the list, which is not
        // where the row went.
        ClipboardHUD.shared.show(
            "已保存到历史", detail: record.preview,
            symbol: "tray.and.arrow.down", style: .success
        )
        return record
    }

    // MARK: - Actions

    func perform(_ action: BuiltinAction) {
        guard settings.enabled else {
            ClipboardHUD.shared.show("剪贴板功能已关闭", symbol: "clipboard", style: .warning)
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
                    ClipboardHUD.shared.show(
                        "没有可复制的内容", symbol: "exclamationmark.triangle", style: .warning
                    )
                    return
                }
                guard let record = self.captureFromPasteboard() else {
                    ClipboardHUD.shared.show("这条内容没有被记录", symbol: "eye.slash", style: .warning)
                    return
                }
                // We already recorded this change; stop the monitor recording it again.
                self.monitor.acceptCurrentAsSeen()
                self.queue.enqueue(record.id)
                NotificationCenter.default.post(name: Self.queueChanged, object: nil)
                // The queue is the one thing in the app with no visible surface of its
                // own at the moment it is used, so the HUD says what went in as well as
                // how many are now waiting.
                ClipboardHUD.shared.show(
                    "已加入队列 · 第 \(self.queue.count) 条",
                    detail: record.preview,
                    symbol: "text.append",
                    style: .success
                )
            }
        }
    }

    /// `Hyper + V`: dispense the next queued entry. With an empty queue it pastes the
    /// most recent history entry, so the binding is never a dead key.
    ///
    /// The whole body waits on the history load. Pressed in the first moments after
    /// launch it used to dequeue an id, fail to find its record in an index that had not
    /// arrived yet, and return — silently destroying the entry it was asked to paste.
    private func pasteNext() {
        store.whenLoaded { [weak self] in
            guard let self else { return }

            // Walk past ids whose records are gone rather than giving up on the first
            // one. An id can go stale between collection and use — deleted from the
            // panel, or evicted — and a queue that refuses to dispense until the user
            // notices and clears it by hand is worse than one that quietly moves on.
            var fromQueue: ClipRecord?
            var dequeued = false
            while let id = self.queue.peek() {
                _ = self.queue.dequeue()
                dequeued = true
                if let record = self.store.record(id: id) {
                    fromQueue = record
                    break
                }
                self.log.info("queued entry \(id.uuidString, privacy: .public) is no longer in the history; skipped")
            }
            if dequeued {
                NotificationCenter.default.post(name: Self.queueChanged, object: nil)
            }

            guard let record = fromQueue ?? self.store.records.first else {
                ClipboardHUD.shared.show("剪贴板历史是空的", symbol: "clipboard", style: .warning)
                return
            }
            let cameFromQueue = fromQueue != nil

            HyperTap.shared.runAfterHyperRelease { [weak self] in
                guard let self else { return }
                self.paste(records: [record], merged: false, plainTextOnly: false, activating: nil)
                let remaining = self.queue.count
                if cameFromQueue, remaining > 0 {
                    // Named as well as counted: `Hyper + V` dispenses blind, and the one
                    // question it leaves is which of the queued entries just went out.
                    ClipboardHUD.shared.show(
                        "已粘贴 · 队列还剩 \(remaining) 条",
                        detail: record.preview,
                        symbol: "text.append",
                        style: .success,
                        duration: 0.9
                    )
                }
            }
        }
    }

    // MARK: - Pasting

    /// The outstanding "put the clipboard back" job, and the content it will put back.
    ///
    /// One of each, not one per paste. ⌘-clicking rows in the panel fires pastes about
    /// 0.2s apart while the restore waits 0.5s, so a second paste that took its own
    /// snapshot would snapshot the entry the *first* paste had just placed — and the
    /// clipboard would end up holding a history row instead of what the user had before
    /// any of it. So the first snapshot is the one that gets restored, and every further
    /// paste in the run cancels the pending restore and re-schedules it.
    private var pendingRestore: DispatchWorkItem?
    private var pendingRestorePayload: ClipPayload?

    /// The single path everything pastes through: place on the pasteboard, make sure
    /// the target application is frontmost, synthesize ⌘V, optionally put the previous
    /// clipboard back.
    ///
    /// `transform` is 「粘贴为…」. It implies plain text — a rewritten body cannot be
    /// carried by the original RTF or HTML, and pretending otherwise would paste the
    /// untransformed styled half into anything that prefers it.
    func paste(
        records: [ClipRecord],
        merged: Bool,
        plainTextOnly: Bool,
        activating app: NSRunningApplication?,
        transform: PasteTransform? = nil
    ) {
        guard !records.isEmpty else { return }

        let payloads = records.compactMap { record -> ClipPayload? in
            guard !record.oversized else { return nil }
            return store.payload(for: record.id)
        }
        guard !payloads.isEmpty else {
            ClipboardHUD.shared.show(
                "这条内容太大，当时没有保存", symbol: "exclamationmark.triangle", style: .warning
            )
            return
        }

        // Taken before anything is written to the pasteboard, and carried over from an
        // unfinished restore rather than re-taken — see `pendingRestore`.
        var previous: ClipPayload?
        if settings.restoreAfterPaste {
            pendingRestore?.cancel()
            pendingRestore = nil
            previous = pendingRestorePayload ?? Paster.snapshot()
            pendingRestorePayload = previous
        }

        let changeCount: Int
        if let transform {
            changeCount = Paster.placeTransformed(
                payloads, separator: settings.joinSeparator, transform: transform
            )
        } else if merged, payloads.count > 1 {
            changeCount = Paster.placeMerged(payloads, separator: settings.joinSeparator)
        } else {
            changeCount = Paster.place(payloads[0], plainTextOnly: plainTextOnly)
        }
        monitor.ignore(changeCount: changeCount)

        Paster.withApplicationFrontmost(app) { [weak self] in
            Paster.sendPaste()
            guard let self, let previous else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let restored = Paster.place(previous, plainTextOnly: false)
                self.monitor.ignore(changeCount: restored)
                self.pendingRestore = nil
                self.pendingRestorePayload = nil
            }
            self.pendingRestore = item
            // Long enough for the target application to have read the pasteboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
    }

    /// Puts an entry on the clipboard without pasting it.
    func copyToClipboard(_ record: ClipRecord, plainTextOnly: Bool) {
        guard let payload = store.payload(for: record.id) else { return }
        let changeCount = Paster.place(payload, plainTextOnly: plainTextOnly)
        monitor.ignore(changeCount: changeCount)
        // The panel is gone by the time this shows, taking the row that was acted on with
        // it — so the HUD repeats what it was.
        ClipboardHUD.shared.show("已复制", detail: record.preview, symbol: "doc.on.doc", style: .success)
    }

    /// Several entries joined into one, put on the clipboard without pasting.
    ///
    /// The merged paste's other half: under 「仅复制并关闭面板」 a multi-row ↩ still has to
    /// join what it was given, or the setting would quietly turn a merge into a copy of
    /// whichever row happened to be first. Same joining as `paste`, minus the keystroke.
    func copyMerged(_ records: [ClipRecord]) {
        let payloads = records.compactMap { record -> ClipPayload? in
            guard !record.oversized else { return nil }
            return store.payload(for: record.id)
        }
        guard !payloads.isEmpty else {
            ClipboardHUD.shared.show(
                "这条内容太大，当时没有保存", symbol: "exclamationmark.triangle", style: .warning
            )
            return
        }
        // One survivor is a copy, not a merge — the separator would have nothing to sit
        // between, and the HUD should not claim a merge that did not happen.
        guard payloads.count > 1 else {
            let changeCount = Paster.place(payloads[0], plainTextOnly: false)
            monitor.ignore(changeCount: changeCount)
            // No summary here: the one payload that survived the size filter is not
            // necessarily `records[0]`, and naming the wrong row is worse than naming none.
            ClipboardHUD.shared.show("已复制", symbol: "doc.on.doc", style: .success)
            return
        }
        let changeCount = Paster.placeMerged(payloads, separator: settings.joinSeparator)
        monitor.ignore(changeCount: changeCount)
        ClipboardHUD.shared.show(
            "已合并复制 \(payloads.count) 条", symbol: "doc.on.doc", style: .success
        )
    }

    /// Puts a string the panel derived — a colour in another notation, say — on the
    /// clipboard.
    ///
    /// Goes through the monitor's ignore list for the same reason every other write
    /// here does: a copy the user did not make should not push a new row into the
    /// history and shove the entry they were looking at down the list.
    func copyPlainString(_ string: String) {
        // Through `Paster` like everything else that touches the pasteboard, so there is
        // one place where "clear, then write" is spelled out and one place to change it.
        let changeCount = Paster.placeText(string)
        monitor.ignore(changeCount: changeCount)
        // Short strings — a colour notation, say — so the summary is usually the whole
        // of what was copied, which is exactly the confirmation this needs to give.
        ClipboardHUD.shared.show("已复制", detail: string, symbol: "doc.on.doc", style: .success)
    }

    // MARK: - Queue, from the panel

    func enqueue(_ ids: [UUID]) {
        queue.enqueue(contentsOf: ids)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    /// Takes an entry out of the queue and leaves the history alone — the panel's queue
    /// tab is a view of the dispensing order, not a second place entries can be deleted
    /// from.
    func removeFromQueue(_ id: UUID) {
        queue.remove(id)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    func moveInQueue(_ id: UUID, up: Bool) {
        if up { queue.moveUp(id) } else { queue.moveDown(id) }
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    func clearQueue() {
        queue.clear()
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }

    func delete(_ id: UUID) {
        delete([id])
    }

    /// The panel's delete, single row or a whole selection. One call per user action
    /// rather than one per row: the store holds a single undo buffer, so deleting five
    /// rows in five calls would make the first four permanent on the way past.
    ///
    /// Recoverable for a few seconds — see `ClipStore.deleteUndoable`. The HUD says so,
    /// because an undo nobody knows about is the same as no undo.
    func delete(_ ids: [UUID]) {
        let removed = store.deleteUndoable(ids)
        guard !removed.isEmpty else { return }
        // The queue holds ids, and one pointing at a row that is no longer in the history
        // dispenses nothing. Undoing puts the rows back but not their places in the
        // dispensing order, which is an order the user arranged and this cannot guess at.
        for record in removed { queue.remove(record.id) }
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
        ClipboardHUD.shared.show(
            "已删除 \(removed.count) 条 · ⌘Z 撤销",
            // Named while there is still time to take it back, and only where there is
            // one name to give: a summary of five rows would be a summary of the first.
            detail: removed.count == 1 ? removed[0].preview : nil,
            symbol: "trash",
            style: .warning,
            duration: 3
        )
    }

    /// ⌘Z in the panel. Returns how many rows came back, so the caller can stay quiet
    /// when the window has already passed.
    @discardableResult
    func undoDelete() -> Int {
        let restored = store.undoLastDelete()
        guard !restored.isEmpty else { return 0 }
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
        ClipboardHUD.shared.show(
            "已恢复 \(restored.count) 条",
            detail: restored.count == 1 ? restored[0].preview : nil,
            symbol: "arrow.uturn.backward",
            style: .success
        )
        return restored.count
    }

    func togglePin(_ id: UUID) {
        store.togglePin(id)
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
    }

    /// Rearranges the 收藏 band, both indices counted within it. Posts like every other
    /// mutation, which is what redraws the list under the pointer mid-drag.
    func movePinned(from source: Int, to destination: Int) {
        store.movePinned(from: source, to: destination)
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
    }

    /// Rewrites a text entry after the editor window closed. Returns the record as it now
    /// stands, so a "save and paste" does not have to look it up again.
    @discardableResult
    func updateText(id: UUID, newText: String) -> ClipRecord? {
        let record = store.updateText(id: id, newText: newText)
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        return record
    }

    func clearHistory(includingPinned: Bool) {
        if includingPinned { store.clearAll() } else { store.clearUnpinned() }
        queue.prune(against: Set(store.records.map(\.id)))
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
    }
}
