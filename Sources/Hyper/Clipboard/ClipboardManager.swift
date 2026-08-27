import AppKit
import Foundation
import os

enum ClipboardItemFailure: Equatable {
    case oversized
    case missingPayload
    case missingRecord
}

enum ClipboardItemState: Equatable {
    case ready
    case completed
    case failed(ClipboardItemFailure)
}

struct ClipboardItemResult: Equatable {
    let id: UUID
    let state: ClipboardItemState
}

enum ClipboardOperationFailure: Equatable {
    case emptySelection
    case preflightFailed
    case accessibilityPermissionDenied
    case targetUnavailable
    case pasteboardWrite(Paster.PlacementFailure)
    case eventDelivery(Paster.EventFailure)
    case operationInProgress
}

enum ClipboardRestoreDisposition: Equatable {
    case notRequested
    case scheduled(expectedChangeCount: Int)
}

/// The result UI and queue code use instead of guessing from side effects. A rejected
/// result always asks the UI to remain available so the user can fix the problem in
/// place; existing panel call sites can adopt that signal without changing this state
/// machine again.
struct ClipboardOperationResult: Equatable {
    let items: [ClipboardItemResult]
    let failure: ClipboardOperationFailure?
    let pasteboardChangeCount: Int?
    let restore: ClipboardRestoreDisposition

    var succeeded: Bool { failure == nil }
    var shouldKeepPanelOpen: Bool { !succeeded }
}

enum ClipboardOperationDispatch: Equatable {
    case scheduled
    case rejected(ClipboardOperationResult)
}

/// Owns the clipboard feature: the history store, the change monitor, the batch queue
/// and the panel. `AppDelegate` starts it; `HyperTap` calls `perform(_:)` when a
/// binding resolves to a built-in action.
final class ClipboardManager {
    struct PasteEnvironment {
        var pasteboard: NSPasteboard
        var accessibilityStatus: () -> Permissions.AccessibilityStatus
        var activate: (NSRunningApplication?, @escaping (Paster.ActivationResult) -> Void) -> Void
        var sendPaste: () -> Result<Paster.EventDelivery, Paster.EventFailure>
        var scheduleRestore: (TimeInterval, DispatchWorkItem) -> Void
        var afterHyperRelease: (@escaping () -> Void) -> Void

        static let live = PasteEnvironment(
            pasteboard: .general,
            accessibilityStatus: { Permissions.accessibilityStatus() },
            activate: { app, completion in
                Paster.withApplicationFrontmost(app, then: completion)
            },
            sendPaste: { Paster.sendPaste() },
            scheduleRestore: { delay, item in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            },
            afterHyperRelease: { body in HyperTap.shared.runAfterHyperRelease(body) }
        )
    }

    static let shared = ClipboardManager()

    static let historyChanged = Notification.Name("com.indincys.hyper.clipboard.historyChanged")
    static let queueChanged = Notification.Name("com.indincys.hyper.clipboard.queueChanged")

    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard")

    let store: ClipStore
    let queue: PasteQueue
    private let monitor = ClipboardMonitor()
    private let pasteEnvironment: PasteEnvironment
    private lazy var panel = ClipboardPanelController(manager: self)

    private(set) var settings: ClipboardSettings
    private var started = false

    /// Retention used to be enforced every time the panel opened, which put an O(n)
    /// walk on the one path that has to feel instant. `insert` already sweeps after
    /// every capture, so the only case left uncovered is a machine left running for
    /// days without a single copy — hence a slow timer rather than anything eager.
    private var sweepTimer: Timer?
    private let sweepInterval: TimeInterval = 3600

    init(
        store: ClipStore = ClipStore(),
        queue: PasteQueue = PasteQueue(),
        settings: ClipboardSettings = ClipboardSettings(),
        pasteEnvironment: PasteEnvironment = .live
    ) {
        self.store = store
        self.queue = queue
        self.settings = settings
        self.pasteEnvironment = pasteEnvironment
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
    ///
    /// Takes the read's answer whole, `nil` included: `ClipDropIntake.read` always calls
    /// back, and this is where a drop that came to nothing gets said out loud. Every other
    /// outcome of a drop — saved, over the cap, images turned off — already ends in a HUD,
    /// and the failure is the one the user is least able to work out on their own: the
    /// list promised in blue that letting go would file the content away, and the row
    /// simply never appears.
    @discardableResult
    func saveDropped(payload: ClipPayload?, kind: ClipKind?) -> ClipRecord? {
        guard settings.enabled else { return nil }
        guard let payload, let kind, !payload.isEmpty else {
            ClipboardHUD.shared.show(
                "没有可保存的内容", symbol: "exclamationmark.triangle", style: .warning
            )
            return nil
        }
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
        pasteEnvironment.afterHyperRelease { [weak self] in
            guard let self else { return }
            _ = Paster.sendCopy()
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
    @discardableResult
    func pasteNext(
        completion: ((ClipboardOperationResult) -> Void)? = nil
    ) -> ClipboardOperationDispatch {
        guard store.isLoaded else {
            store.whenLoaded { [weak self] in _ = self?.pasteNext(completion: completion) }
            return .scheduled
        }

        let ticket: PasteQueue.DequeueTicket?
        if queue.isEmpty {
            ticket = nil
        } else if let prepared = queue.prepareDequeue() {
            ticket = prepared
        } else {
            let id = queue.peek()
            let result = ClipboardOperationResult(
                items: id.map { [ClipboardItemResult(id: $0, state: .ready)] } ?? [],
                failure: .operationInProgress, pasteboardChangeCount: nil,
                restore: .notRequested
            )
            presentPasteFailure(result)
            completion?(result)
            return .rejected(result)
        }
        let record: ClipRecord
        if let ticket, let id = queue.peek() {
            guard let queuedRecord = store.record(id: id) else {
                queue.rollbackDequeue(ticket)
                let result = ClipboardOperationResult(
                    items: [ClipboardItemResult(id: id, state: .failed(.missingRecord))],
                    failure: .preflightFailed,
                    pasteboardChangeCount: nil,
                    restore: .notRequested
                )
                presentPasteFailure(result)
                completion?(result)
                return .rejected(result)
            }
            record = queuedRecord
        } else {
            guard let recent = store.records.first else {
                let result = ClipboardOperationResult(
                    items: [], failure: .emptySelection, pasteboardChangeCount: nil,
                    restore: .notRequested
                )
                ClipboardHUD.shared.show("剪贴板历史是空的", symbol: "clipboard", style: .warning)
                completion?(result)
                return .rejected(result)
            }
            record = recent
        }

        let cameFromQueue = ticket != nil
        var returned: ClipboardOperationDispatch = .scheduled
        pasteEnvironment.afterHyperRelease { [weak self] in
            guard let self else { return }
            returned = self.paste(
                records: [record], merged: false, plainTextOnly: false, activating: nil
            ) { [weak self] result in
                guard let self else { return }
                if let ticket {
                    if result.succeeded {
                        if self.queue.commitDequeue(ticket) != nil {
                            NotificationCenter.default.post(name: Self.queueChanged, object: nil)
                        }
                    } else {
                        self.queue.rollbackDequeue(ticket)
                    }
                }
                completion?(result)
                let remaining = self.queue.count
                if cameFromQueue, result.succeeded, remaining > 0 {
                    ClipboardHUD.shared.show(
                        "已粘贴 · 队列还剩 \(remaining) 条", detail: record.preview,
                        symbol: "text.append", style: .success, duration: 0.9
                    )
                }
            }
        }
        return returned
    }

    // MARK: - Pasting

    private var pendingRestore: DispatchWorkItem?
    private var pendingRestoreSnapshot: Paster.PasteboardSnapshot?
    private var pendingRestoreToken: UUID?

    private struct PreparedBatch {
        let records: [ClipRecord]
        let payloads: [ClipPayload]
        let itemResults: [ClipboardItemResult]
    }

    private enum PreflightResult {
        case success(PreparedBatch)
        case failure(ClipboardOperationResult)
    }

    private struct PasteRequest {
        let prepared: PreparedBatch
        let merged: Bool
        let plainTextOnly: Bool
        let app: NSRunningApplication?
        let transform: PasteTransform?
        let separator: String
        let restoreAfterPaste: Bool
        let completion: ((ClipboardOperationResult) -> Void)?
    }

    private var pasteRequests: [PasteRequest] = []
    private var pasteInFlight = false

    /// The single path everything pastes through: place on the pasteboard, make sure
    /// the target application is frontmost, synthesize ⌘V, optionally put the previous
    /// clipboard back.
    ///
    /// `transform` is 「粘贴为…」. It implies plain text — a rewritten body cannot be
    /// carried by the original RTF or HTML, and pretending otherwise would paste the
    /// untransformed styled half into anything that prefers it.
    @discardableResult
    func paste(
        records: [ClipRecord],
        merged: Bool,
        plainTextOnly: Bool,
        activating app: NSRunningApplication?,
        transform: PasteTransform? = nil,
        completion: ((ClipboardOperationResult) -> Void)? = nil
    ) -> ClipboardOperationDispatch {
        switch preflight(records) {
        case .failure(let result):
            presentPasteFailure(result)
            completion?(result)
            return .rejected(result)
        case .success(let prepared):
            guard pasteEnvironment.accessibilityStatus() == .granted else {
                let result = ClipboardOperationResult(
                    items: prepared.itemResults,
                    failure: .accessibilityPermissionDenied,
                    pasteboardChangeCount: nil,
                    restore: .notRequested
                )
                presentPasteFailure(result)
                completion?(result)
                return .rejected(result)
            }
            pasteRequests.append(
                PasteRequest(
                    prepared: prepared, merged: merged, plainTextOnly: plainTextOnly,
                    app: app, transform: transform, separator: settings.joinSeparator,
                    restoreAfterPaste: settings.restoreAfterPaste, completion: completion
                )
            )
            drainPasteRequests()
            return .scheduled
        }
    }

    private func preflight(
        _ records: [ClipRecord]
    ) -> PreflightResult {
        guard !records.isEmpty else {
            return .failure(
                ClipboardOperationResult(
                    items: [], failure: .emptySelection, pasteboardChangeCount: nil,
                    restore: .notRequested
                )
            )
        }
        var payloads: [ClipPayload] = []
        var items: [ClipboardItemResult] = []
        var failed = false
        for record in records {
            if record.oversized {
                items.append(ClipboardItemResult(id: record.id, state: .failed(.oversized)))
                failed = true
            } else if let payload = store.payload(for: record.id) {
                payloads.append(payload)
                items.append(ClipboardItemResult(id: record.id, state: .ready))
            } else {
                items.append(ClipboardItemResult(id: record.id, state: .failed(.missingPayload)))
                failed = true
            }
        }
        guard !failed else {
            return .failure(
                ClipboardOperationResult(
                    items: items, failure: .preflightFailed, pasteboardChangeCount: nil,
                    restore: .notRequested
                )
            )
        }
        return .success(PreparedBatch(records: records, payloads: payloads, itemResults: items))
    }

    private func drainPasteRequests() {
        guard !pasteInFlight, !pasteRequests.isEmpty else { return }
        pasteInFlight = true
        let request = pasteRequests.removeFirst()

        var snapshot: Paster.PasteboardSnapshot?
        if request.restoreAfterPaste {
            pendingRestore?.cancel()
            pendingRestore = nil
            pendingRestoreToken = nil
            snapshot = pendingRestoreSnapshot ?? Paster.snapshot(pasteEnvironment.pasteboard)
            pendingRestoreSnapshot = snapshot
        }

        let placement: Result<Paster.Placement, Paster.PlacementFailure>
        if let transform = request.transform {
            placement = Paster.placeTransformed(
                request.prepared.payloads, separator: request.separator, transform: transform,
                to: pasteEnvironment.pasteboard
            )
        } else if request.merged, request.prepared.payloads.count > 1 {
            placement = Paster.placeMerged(
                request.prepared.payloads, separator: request.separator,
                to: pasteEnvironment.pasteboard
            )
        } else {
            placement = Paster.place(
                request.prepared.payloads[0], plainTextOnly: request.plainTextOnly,
                to: pasteEnvironment.pasteboard
            )
        }

        guard case .success(let placed) = placement else {
            let failure: Paster.PlacementFailure
            if case .failure(let value) = placement { failure = value } else { fatalError() }
            finishPaste(
                request,
                result: ClipboardOperationResult(
                    items: request.prepared.itemResults,
                    failure: .pasteboardWrite(failure), pasteboardChangeCount: nil,
                    restore: .notRequested
                )
            )
            return
        }
        monitor.ignore(changeCount: placed.changeCount)

        pasteEnvironment.activate(request.app) { [weak self] activation in
            guard let self else { return }
            guard activation == .ready else {
                self.scheduleRestoreIfNeeded(
                    snapshot, expectedChangeCount: placed.changeCount, delay: 0
                )
                self.finishPaste(
                    request,
                    result: ClipboardOperationResult(
                        items: request.prepared.itemResults, failure: .targetUnavailable,
                        pasteboardChangeCount: placed.changeCount,
                        restore: snapshot == nil ? .notRequested : .scheduled(expectedChangeCount: placed.changeCount)
                    )
                )
                return
            }

            switch self.pasteEnvironment.sendPaste() {
            case .failure(let failure):
                self.scheduleRestoreIfNeeded(
                    snapshot, expectedChangeCount: placed.changeCount, delay: 0
                )
                self.finishPaste(
                    request,
                    result: ClipboardOperationResult(
                        items: request.prepared.itemResults,
                        failure: .eventDelivery(failure),
                        pasteboardChangeCount: placed.changeCount,
                        restore: snapshot == nil ? .notRequested : .scheduled(expectedChangeCount: placed.changeCount)
                    )
                )
            case .success:
                let delay = Paster.restoreDelay(activating: request.app)
                self.scheduleRestoreIfNeeded(
                    snapshot, expectedChangeCount: placed.changeCount, delay: delay
                )
                self.finishPaste(
                    request,
                    result: ClipboardOperationResult(
                        items: request.prepared.records.map {
                            ClipboardItemResult(id: $0.id, state: .completed)
                        },
                        failure: nil,
                        pasteboardChangeCount: placed.changeCount,
                        restore: snapshot == nil ? .notRequested : .scheduled(expectedChangeCount: placed.changeCount)
                    )
                )
            }
        }
    }

    private func finishPaste(_ request: PasteRequest, result: ClipboardOperationResult) {
        if !result.succeeded { presentPasteFailure(result) }
        request.completion?(result)
        pasteInFlight = false
        drainPasteRequests()
    }

    private func scheduleRestoreIfNeeded(
        _ snapshot: Paster.PasteboardSnapshot?, expectedChangeCount: Int, delay: TimeInterval
    ) {
        guard let snapshot else { return }
        pendingRestore?.cancel()
        let token = UUID()
        pendingRestoreToken = token
        var work: DispatchWorkItem?
        work = DispatchWorkItem { [weak self] in
            guard let self, work?.isCancelled == false, self.pendingRestoreToken == token else {
                return
            }
            let result = Paster.restore(
                snapshot, ifUnchangedSince: expectedChangeCount,
                to: self.pasteEnvironment.pasteboard
            )
            if case .restored(let changeCount) = result {
                self.monitor.ignore(changeCount: changeCount)
            }
            self.pendingRestore = nil
            self.pendingRestoreToken = nil
            self.pendingRestoreSnapshot = nil
        }
        guard let work else { return }
        pendingRestore = work
        pasteEnvironment.scheduleRestore(delay, work)
    }

    private func presentPasteFailure(_ result: ClipboardOperationResult) {
        let message: String
        switch result.failure {
        case .accessibilityPermissionDenied:
            message = "需要辅助功能权限，内容仍保留"
        case .targetUnavailable:
            message = "目标应用不可用，内容仍保留"
        case .eventDelivery:
            message = "粘贴事件发送失败，内容仍保留"
        case .preflightFailed:
            message = "所选内容不完整，操作已全部取消"
        case .pasteboardWrite:
            message = "无法写入剪贴板，操作已取消"
        case .operationInProgress:
            message = "上一项仍在粘贴，请稍后重试"
        case .emptySelection, .none:
            message = "没有可粘贴的内容"
        }
        ClipboardHUD.shared.show(message, symbol: "exclamationmark.triangle", style: .warning)
    }

    /// Puts an entry on the clipboard without pasting it.
    @discardableResult
    func copyToClipboard(
        _ record: ClipRecord, plainTextOnly: Bool
    ) -> ClipboardOperationResult {
        switch preflight([record]) {
        case .failure(let result):
            presentPasteFailure(result)
            return result
        case .success(let prepared):
            let placement = Paster.place(
                prepared.payloads[0], plainTextOnly: plainTextOnly,
                to: pasteEnvironment.pasteboard
            )
            return finishCopy(
                placement, prepared: prepared, successMessage: "已复制", detail: record.preview
            )
        }
    }

    /// Several entries joined into one, put on the clipboard without pasting.
    ///
    /// The merged paste's other half: under 「仅复制并关闭面板」 a multi-row ↩ still has to
    /// join what it was given, or the setting would quietly turn a merge into a copy of
    /// whichever row happened to be first. Same joining as `paste`, minus the keystroke.
    @discardableResult
    func copyMerged(_ records: [ClipRecord]) -> ClipboardOperationResult {
        switch preflight(records) {
        case .failure(let result):
            presentPasteFailure(result)
            return result
        case .success(let prepared):
            let placement: Result<Paster.Placement, Paster.PlacementFailure>
            let message: String
            if prepared.payloads.count == 1 {
                placement = Paster.place(
                    prepared.payloads[0], plainTextOnly: false,
                    to: pasteEnvironment.pasteboard
                )
                message = "已复制"
            } else {
                placement = Paster.placeMerged(
                    prepared.payloads, separator: settings.joinSeparator,
                    to: pasteEnvironment.pasteboard
                )
                message = "已合并复制 \(prepared.payloads.count) 条"
            }
            return finishCopy(placement, prepared: prepared, successMessage: message, detail: nil)
        }
    }

    private func finishCopy(
        _ placement: Result<Paster.Placement, Paster.PlacementFailure>,
        prepared: PreparedBatch,
        successMessage: String,
        detail: String?
    ) -> ClipboardOperationResult {
        switch placement {
        case .failure(let failure):
            let result = ClipboardOperationResult(
                items: prepared.itemResults, failure: .pasteboardWrite(failure),
                pasteboardChangeCount: nil, restore: .notRequested
            )
            presentPasteFailure(result)
            return result
        case .success(let placed):
            monitor.ignore(changeCount: placed.changeCount)
            ClipboardHUD.shared.show(
                successMessage, detail: detail, symbol: "doc.on.doc", style: .success
            )
            return ClipboardOperationResult(
                items: prepared.records.map { ClipboardItemResult(id: $0.id, state: .completed) },
                failure: nil, pasteboardChangeCount: placed.changeCount, restore: .notRequested
            )
        }
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
        guard case .success(let placement) = Paster.placeText(
            string, to: pasteEnvironment.pasteboard
        ) else {
            ClipboardHUD.shared.show(
                "无法写入剪贴板", symbol: "exclamationmark.triangle", style: .warning
            )
            return
        }
        monitor.ignore(changeCount: placement.changeCount)
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
