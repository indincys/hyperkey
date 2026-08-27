import AppKit
import Foundation
import os

enum ClipboardItemFailure: Equatable {
    case oversized
    case missingPayload
    case missingRecord
}

enum ClipboardItemPreflightFailure: Equatable {
    case incompatiblePayload
}

enum ClipboardItemState: Equatable {
    case ready
    case completed
    case failed(ClipboardItemFailure)
    case failedPreflight(ClipboardItemPreflightFailure)
}

enum ClipboardBatchPolicy: Equatable {
    case allOrNothing
    case skipInvalid
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
    case attempted(Paster.RestoreResult)
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

enum ClipboardShutdownDrainResult: Equatable {
    case drained
    case incomplete(
        timeout: TimeInterval,
        queue: PasteQueue.FlushResult,
        storeDrained: Bool
    )
}

private final class ClipboardCaptureSession {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// The only executor allowed to materialise pasteboard providers for live capture.
/// One job may run and one latest job may wait; further changes replace that waiter.
/// A provider cannot be force-cancelled by AppKit, so a timed-out job continues on this
/// same worker instead of spawning replacement threads and multiplying memory pressure.
final class ClipboardCaptureWorker {
    enum Result {
        case completed(ClipCapture.Outcome, elapsed: TimeInterval)
        case stale
        case timedOut(elapsed: TimeInterval)
    }

    struct Snapshot {
        let inflight: Int
        let backlog: Int
        let hungWorkers: Int
        let maximumInflight: Int
        let maximumBacklog: Int
        let maximumHungWorkers: Int
        let coalesced: Int
    }

    typealias Reader = (NSPasteboard, ClipCapture.Options) -> ClipCapture.Outcome
    typealias Completion = (Result, @escaping () -> Void) -> Void

    private struct Job {
        let id = UUID()
        let pasteboard: NSPasteboard
        let expectedChangeCount: Int
        let options: ClipCapture.Options
        let completion: Completion
    }

    private struct ActiveJob {
        let job: Job
        var began: TimeInterval?
        var providerReturned = false
        var resultDelivered = false
        var completionAcknowledged = false
        var timedOut = false
        var cancelled = false
    }

    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let reader: Reader
    private let lock = NSLock()
    private var active: ActiveJob?
    private var pending: Job?
    private var maximumInflight = 0
    private var maximumBacklog = 0
    private var maximumHungWorkers = 0
    private var coalesced = 0

    init(
        timeout: TimeInterval = 2,
        queue: DispatchQueue? = nil,
        reader: @escaping Reader = { ClipCapture.read($0, options: $1) }
    ) {
        self.timeout = max(0, timeout)
        self.queue = queue ?? DispatchQueue(
            label: "dev.hyper.clipboard.capture-provider", qos: .userInitiated
        )
        self.reader = reader
    }

    func submit(
        pasteboard: NSPasteboard, expectedChangeCount: Int,
        options: ClipCapture.Options, completion: @escaping Completion
    ) {
        let job = Job(
            pasteboard: pasteboard, expectedChangeCount: expectedChangeCount,
            options: options, completion: completion
        )
        lock.lock()
        if active != nil {
            if pending != nil { coalesced += 1 }
            pending = job
            maximumBacklog = max(maximumBacklog, 1)
            lock.unlock()
            return
        }
        active = ActiveJob(job: job)
        maximumInflight = 1
        lock.unlock()
        enqueue(job)
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            inflight: active == nil ? 0 : 1,
            backlog: pending == nil ? 0 : 1,
            hungWorkers: active.map { $0.timedOut && !$0.providerReturned ? 1 : 0 } ?? 0,
            maximumInflight: maximumInflight,
            maximumBacklog: maximumBacklog,
            maximumHungWorkers: maximumHungWorkers,
            coalesced: coalesced
        )
    }

    func discardPending() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    /// Invalidates every accepted result without pretending an in-progress AppKit
    /// provider can be cancelled. The one physical reader remains the circuit breaker;
    /// a later submission becomes the sole pending job and starts after it returns.
    func cancelAll() {
        lock.lock()
        pending = nil
        if var current = active {
            current.cancelled = true
            current.completionAcknowledged = true
            active = current
            if current.providerReturned {
                active = nil
            }
        }
        lock.unlock()
    }

    private func enqueue(_ job: Job) {
        queue.async { [weak self] in self?.run(job) }
    }

    private func run(_ job: Job) {
        lock.lock()
        guard var current = active, current.job.id == job.id else {
            lock.unlock()
            return
        }
        if current.cancelled {
            current.providerReturned = true
            active = current
            let next = promoteIfFinishedLocked()
            lock.unlock()
            if let next { enqueue(next) }
            return
        }
        let began = ProcessInfo.processInfo.systemUptime
        current.began = began
        active = current
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            [weak self] in self?.deadlineReached(for: job.id)
        }

        guard job.pasteboard.changeCount == job.expectedChangeCount else {
            providerReturned(.stale, job: job)
            return
        }
        let outcome = reader(job.pasteboard, job.options)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        guard job.pasteboard.changeCount == job.expectedChangeCount else {
            providerReturned(.stale, job: job)
            return
        }
        providerReturned(.completed(outcome, elapsed: elapsed), job: job)
    }

    private func deadlineReached(for id: UUID) {
        var delivery: (Job, Result)?
        lock.lock()
        if var current = active, current.job.id == id,
           !current.cancelled, !current.providerReturned, !current.resultDelivered,
           let began = current.began {
            current.timedOut = true
            current.resultDelivered = true
            active = current
            maximumHungWorkers = max(maximumHungWorkers, 1)
            delivery = (
                current.job,
                .timedOut(elapsed: ProcessInfo.processInfo.systemUptime - began)
            )
        }
        lock.unlock()
        if let delivery {
            delivery.0.completion(delivery.1) { [weak self] in
                self?.acknowledge(delivery.0.id)
            }
        }
    }

    private func providerReturned(_ result: Result, job: Job) {
        var delivery: (Job, Result)?
        var next: Job?
        lock.lock()
        guard var current = active, current.job.id == job.id else {
            lock.unlock()
            return
        }
        current.providerReturned = true
        if current.cancelled {
            current.completionAcknowledged = true
        } else if !current.resultDelivered {
            current.resultDelivered = true
            delivery = (job, result)
        }
        active = current
        next = promoteIfFinishedLocked()
        lock.unlock()

        if let delivery {
            delivery.0.completion(delivery.1) { [weak self] in
                self?.acknowledge(delivery.0.id)
            }
        }
        if let next { enqueue(next) }
    }

    private func acknowledge(_ id: UUID) {
        var next: Job?
        lock.lock()
        if var current = active, current.job.id == id {
            current.completionAcknowledged = true
            active = current
            next = promoteIfFinishedLocked()
        }
        lock.unlock()
        if let next { enqueue(next) }
    }

    /// Called with `lock` held. A timed-out provider is intentionally not promoted past
    /// until it physically returns: this is what caps unkillable provider work at one.
    private func promoteIfFinishedLocked() -> Job? {
        guard let current = active,
              current.providerReturned, current.completionAcknowledged else { return nil }
        if let next = pending {
            pending = nil
            active = ActiveJob(job: next)
            return next
        }
        active = nil
        return nil
    }
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
    static let privacyStateChanged = Notification.Name(
        "com.indincys.hyper.clipboard.privacyStateChanged"
    )

    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard")

    let store: ClipStore
    let queue: PasteQueue
    private let monitor: ClipboardMonitor
    private let captureWorker: ClipboardCaptureWorker
    private var captureSession = ClipboardCaptureSession()
    private let pasteEnvironment: PasteEnvironment
    private let drainStore: (TimeInterval) -> Bool
    private let now: () -> Date
    private lazy var panel = ClipboardPanelController(manager: self)

    private(set) var settings: ClipboardSettings
    private var started = false
    private var applicationEnabled = true
    private var shutdownResult: ClipboardShutdownDrainResult?
    private var privacyTimer: Timer?
    private var systemSuspended = false
    private var observedCaptureRunning: Bool?
    private var publishedPauseState: ClipboardPauseState?

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
        pasteEnvironment: PasteEnvironment = .live,
        monitor: ClipboardMonitor? = nil,
        captureWorker: ClipboardCaptureWorker? = nil,
        drainStore: ((TimeInterval) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.queue = queue
        self.settings = settings
        self.pasteEnvironment = pasteEnvironment
        self.monitor = monitor ?? ClipboardMonitor(pasteboard: pasteEnvironment.pasteboard)
        self.captureWorker = captureWorker ?? ClipboardCaptureWorker()
        self.drainStore = drainStore ?? { timeout in store.drainPendingWrites(timeout: timeout) }
        self.now = now
        self.monitor.onChange = { [weak self] source in
            self?.scheduleCaptureFromPasteboard(source: source)
        }
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

    deinit {
        captureSession.cancel()
        monitor.onChange = nil
        monitor.stop()
        captureWorker.cancelAll()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started, featureEnabled, shutdownResult == nil else { return }
        captureSession = ClipboardCaptureSession()
        started = true

        // Capture starts straight away — the history is read from disk in the
        // background, and a copy made during those first milliseconds is merged in
        // rather than lost.
        monitor.acceptCurrentAsSeen()
        if captureEnabled { monitor.start() }
        observedCaptureRunning = captureEnabled
        observeSystem()
        startSweepTimer()
        schedulePrivacyTimer()

        // Everything below reads `store.records`, so it has to wait for the load.
        // `reconcileOrphans` especially: run against an empty array it would delete
        // every payload file on disk.
        queue.restore()
        store.whenLoaded { [weak self] in
            guard let self else { return }
            self.store.sweep()
            self.purgeExpiredSensitiveRecords()
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
        captureSession.cancel()
        monitor.stop()
        observedCaptureRunning = nil
        captureWorker.cancelAll()
        sweepTimer?.invalidate()
        sweepTimer = nil
        privacyTimer?.invalidate()
        privacyTimer = nil
        panel.hide()
        store.flushNow()
        queue.flushNow()
        log.info("clipboard feature stopped")
    }

    func applicationWillTerminate() {
        _ = applicationWillTerminate(drainTimeout: 2)
    }

    /// Freezes capture first, then gives every accepted store write one bounded chance
    /// to become durable. A failure is reported but never retried in an unbounded loop:
    /// termination must not hang forever on a damaged disk or provider.
    @discardableResult
    func applicationWillTerminate(drainTimeout: TimeInterval) -> ClipboardShutdownDrainResult {
        if let shutdownResult { return shutdownResult }

        started = false
        captureSession.cancel()
        monitor.stop()
        monitor.onChange = nil
        observedCaptureRunning = nil
        captureWorker.cancelAll()
        sweepTimer?.invalidate()
        sweepTimer = nil
        privacyTimer?.invalidate()
        privacyTimer = nil
        let boundedTimeout = max(0, drainTimeout)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let queueResult = queue.flushPendingWrites(timeout: boundedTimeout)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let remaining = max(0, boundedTimeout - elapsed)
        let storeDrained = drainStore(remaining)

        let outcome: ClipboardShutdownDrainResult
        if queueResult.succeeded, storeDrained {
            outcome = .drained
            log.info("event=clipboard_shutdown_drain status=drained timeout_seconds=\(boundedTimeout, privacy: .public)")
        } else {
            outcome = .incomplete(
                timeout: boundedTimeout, queue: queueResult, storeDrained: storeDrained
            )
            log.error(
                "event=clipboard_shutdown_drain status=incomplete timeout_seconds=\(boundedTimeout, privacy: .public) queue=\(String(describing: queueResult), privacy: .public) store_drained=\(storeDrained, privacy: .public)"
            )
        }
        shutdownResult = outcome
        return outcome
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

    private var featureEnabled: Bool { applicationEnabled && settings.enabled }

    private var captureEnabled: Bool { featureEnabled && pauseState == nil }

    var pauseState: ClipboardPauseState? {
        guard let resumesAt = settings.pauseUntil, resumesAt > now() else { return nil }
        return ClipboardPauseState(reason: .manualPrivacyPause, resumesAt: resumesAt)
    }

    func apply(_ settings: ClipboardSettings, applicationEnabled: Bool = true) {
        self.settings = settings
        self.applicationEnabled = applicationEnabled
        store.retentionDays = settings.retentionDays
        store.maxItems = settings.maxItems
        if featureEnabled {
            start()
            refreshPrivacyState()
            // Retention may just have been tightened, so re-apply it — but not before
            // the history is in memory, or there would be nothing to apply it to.
            store.whenLoaded { [weak self] in
                self?.sweepNow()
                self?.refreshPrivacyState()
            }
        } else {
            stop()
            // Turning history capture off is not permission to keep an already stored
            // secret past its deadline. The expiry lifecycle remains active on its own.
            store.whenLoaded { [weak self] in self?.refreshPrivacyState() }
        }
    }

    /// Reconciles both time-based privacy mechanisms. Public for deterministic lifecycle
    /// tests; production reaches it through the exact next-deadline timer.
    func refreshPrivacyState() {
        guard shutdownResult == nil else { return }
        purgeExpiredSensitiveRecords()

        let shouldRunCapture = captureEnabled && !systemSuspended
        if featureEnabled, observedCaptureRunning != shouldRunCapture {
            captureSession.cancel()
            captureWorker.cancelAll()
            captureSession = ClipboardCaptureSession()
            if shouldRunCapture {
                // A privacy pause must never replay whatever accumulated while no observer
                // was running. Establishing the current change count before start is the
                // no-backfill contract.
                monitor.acceptCurrentAsSeen()
                monitor.start()
            } else {
                monitor.stop()
            }
            observedCaptureRunning = shouldRunCapture
        }
        schedulePrivacyTimer()
        let currentPauseState = pauseState
        if currentPauseState != publishedPauseState {
            publishedPauseState = currentPauseState
            NotificationCenter.default.post(name: Self.privacyStateChanged, object: nil)
        }
    }

    private func schedulePrivacyTimer() {
        privacyTimer?.invalidate()
        privacyTimer = nil
        guard shutdownResult == nil else { return }
        let current = now()
        let pauseDeadline = featureEnabled ? settings.pauseUntil : nil
        let deadlines = ([pauseDeadline] + store.records.map(\.expiry))
            .compactMap { $0 }
            .filter { $0 > current }
        guard let next = deadlines.min() else { return }
        let interval = max(0.001, next.timeIntervalSince(current))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refreshPrivacyState()
        }
        RunLoop.main.add(timer, forMode: .common)
        privacyTimer = timer
    }

    private func purgeExpiredSensitiveRecords() {
        guard store.isLoaded else { return }
        let current = now()
        let ids: [UUID] = store.records.compactMap { record -> UUID? in
            guard let expiry = record.expiry, expiry <= current else { return nil }
            return record.id
        }
        permanentlyDeleteSensitiveRecords(ids)
    }

    private func permanentlyDeleteSensitiveRecords(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let removed = store.deleteUndoable(ids)
        guard !removed.isEmpty else { return }
        // Privacy lifecycle deletion has no undo window: retaining plaintext for a
        // convenience action would make the visible expiry claim false.
        store.commitPendingDeletion()
        for record in removed { queue.remove(record.id) }
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
        NotificationCenter.default.post(name: Self.queueChanged, object: nil)
        log.info("permanently deleted \(removed.count) expired/consumed sensitive entries")
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemSuspended = true
            self?.monitor.suspend()
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resumeAfterSystemSuspension() }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemSuspended = true
            self?.monitor.suspend()
        }
        distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.resumeAfterSystemSuspension() }
    }

    private func resumeAfterSystemSuspension() {
        systemSuspended = false
        // `resume` clears ClipboardMonitor's own suspension bit. Its immediate check is
        // harmless during a privacy pause because scheduleCapture gates on captureEnabled;
        // stopping it again leaves a correct baseline for the later manual resume.
        monitor.resume()
        if !captureEnabled { monitor.stop() }
    }

    /// Called by the event tap the instant it sees a copy keystroke. This is the fast
    /// path: it makes the common case event-driven and lets the backstop timer run
    /// slower than a poll-only design could get away with.
    func copyKeystrokeObserved(source: ClipboardCaptureSource) {
        guard started, captureEnabled else { return }
        monitor.checkSoon(source: source)
    }

    // MARK: - Capture

    private func captureOptions(for rule: ClipboardApplicationRule?) -> ClipCapture.Options {
        ClipCapture.Options(
            // textOnly is reduced after reading because a rich item may offer both a
            // safe plain string and an image/styled representation. noImages can reject
            // image-classified items before their providers are materialised.
            recordImages: settings.recordImages && rule != .noImages,
            skipConcealed: settings.skipConcealed,
            skipTransient: settings.skipTransient,
            maxItemBytes: settings.maxItemBytes
        )
    }

    @discardableResult
    private func captureRule(for source: ClipboardCaptureSource) -> ClipboardApplicationRule? {
        if let bundleID = source.bundleIdentifier {
            return settings.applicationRules[bundleID]
        }

        // Polling cannot identify the writer. Do not pretend the app that is frontmost
        // now owned a change that may be 1.5 seconds old. When rules exist, enforce the
        // strictest one so an ignored/restricted source cannot bypass privacy by copying
        // from a menu or switching applications before the poll.
        let rules = settings.applicationRules.values
        if rules.contains(.ignore) { return .ignore }
        if rules.contains(.textOnly) { return .textOnly }
        if rules.contains(.noImages) { return .noImages }
        return nil
    }

    private static let plainTextTypes = Set([
        NSPasteboard.PasteboardType.string.rawValue,
        "public.utf8-plain-text",
        "public.text",
    ])

    private func textOnlyPayload(_ payload: ClipPayload) -> ClipPayload? {
        let filtered = payload.compactMap { item -> [String: Data]? in
            let safe = item.filter { Self.plainTextTypes.contains($0.key) }
            return safe.isEmpty ? nil : safe
        }
        guard !filtered.isEmpty, ClipCapture.plainTextOnly(from: filtered) != nil else { return nil }
        return filtered
    }

    private func scheduleCaptureFromPasteboard(
        source: ClipboardCaptureSource, completion: ((ClipRecord?) -> Void)? = nil
    ) {
        guard started, captureEnabled else {
            completion?(nil)
            return
        }

        let rule = captureRule(for: source)
        if rule == .ignore {
            log.info("event=clipboard_capture status=ignored reason=application_rule attribution=\(String(describing: source.attribution), privacy: .public)")
            completion?(nil)
            return
        }

        let pasteboard = pasteEnvironment.pasteboard
        let expectedChangeCount = pasteboard.changeCount
        // Reading advertised type names materialises no provider bytes. Bind this marker
        // snapshot to the same expected transaction before the async worker starts.
        let offeredTypes = Set(
            (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        )
        let options = captureOptions(for: rule)
        let sensitiveHandling = settings.sensitiveHandling
        let sensitiveTTLMinutes = settings.sensitiveTTLMinutes
        let capturedAt = now()
        let session = captureSession
        captureWorker.submit(
            pasteboard: pasteboard, expectedChangeCount: expectedChangeCount, options: options
        ) { [weak self] result, done in
            guard let self else {
                done()
                return
            }
            guard !session.isCancelled else {
                done()
                return
            }
            switch result {
            case .stale:
                self.log.info("clipboard capture superseded by a newer pasteboard change")
                DispatchQueue.main.async { completion?(nil) }
                done()
            case .timedOut(let elapsed):
                self.log.error("clipboard provider exceeded capture timeout after \(elapsed, privacy: .public)s; provider was not force-cancelled")
                DispatchQueue.main.async { completion?(nil) }
                done()
            case .completed(let outcome, _):
                self.prepareCapturedOutcome(
                    outcome, source: source, rule: rule,
                    offeredTypes: offeredTypes, sensitiveHandling: sensitiveHandling,
                    sensitiveTTLMinutes: sensitiveTTLMinutes, capturedAt: capturedAt,
                    session: session, completion: completion, workerDone: done
                )
            }
        }
    }

    /// Runs off-main. Provider bytes are already materialised; everything here is pure
    /// payload reduction and preparation until the final main-thread commit.
    private func prepareCapturedOutcome(
        _ outcome: ClipCapture.Outcome,
        source: ClipboardCaptureSource,
        rule: ClipboardApplicationRule?,
        offeredTypes: Set<String>,
        sensitiveHandling: SensitiveClipboardHandling,
        sensitiveTTLMinutes: Int,
        capturedAt: Date,
        session: ClipboardCaptureSession,
        completion: ((ClipRecord?) -> Void)?,
        workerDone: @escaping () -> Void
    ) {
        switch outcome {
        case .ignored(let reason):
            // Info, not debug. "I copied something and it did not show up" is the
            // question this feature will actually be asked, and os_log's debug level
            // is memory-only — by the time anyone reads the log it is already gone.
            log.info("clipboard change ignored: \(reason, privacy: .public)")
            DispatchQueue.main.async { completion?(nil) }
            workerDone()

        case .captured(let capturedPayload, let capturedKind, var reduction):
            let payload: ClipPayload
            let kind: ClipKind
            if rule == .textOnly {
                guard let textPayload = textOnlyPayload(capturedPayload) else {
                    log.info("clipboard change ignored: application allows text only")
                    DispatchQueue.main.async { completion?(nil) }
                    workerDone()
                    return
                }
                payload = textPayload
                kind = capturedKind == .url ? .url : .text
                reduction.byteSize = ClipPayloadCoder.byteSize(textPayload)
            } else {
                // `recordImages=false` already rejects image-classified items before
                // providers are read. Keep a second insertion-side guard so a future
                // classifier change cannot weaken this privacy rule by accident.
                guard rule != .noImages || capturedKind != .image else {
                    log.info("clipboard change ignored: application disallows images")
                    DispatchQueue.main.async { completion?(nil) }
                    workerDone()
                    return
                }
                payload = capturedPayload
                kind = capturedKind
            }
            ClipCapture.analyzePayloadOffMain(payload) { [weak self] analysis in
                guard let self, !session.isCancelled else {
                    workerDone()
                    return
                }
                let sensitivity = SensitiveClipboardPolicy.classify(
                    offeredTypes: offeredTypes, text: analysis.plainText
                )
                let privacyDecision = SensitiveClipboardPolicy.decision(
                    for: sensitivity, handling: sensitiveHandling,
                    ttlMinutes: sensitiveTTLMinutes, now: capturedAt
                )
                if privacyDecision == .skip {
                    self.log.info("clipboard change ignored: sensitive retention policy")
                    DispatchQueue.main.async { completion?(nil) }
                    workerDone()
                    return
                }
                let prepared = ClipStore.prepareCapturedPayload(
                    payload, kind: kind, analysis: analysis
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, !session.isCancelled,
                          self.started, self.captureEnabled else {
                        workerDone()
                        return
                    }
                    let privacy: (
                        sensitivity: ClipSensitivity?, expiry: Date?, oneTime: Bool
                    )
                    switch privacyDecision {
                    case .none:
                        privacy = (nil, nil, false)
                    case .skip:
                        // Handled off-main above; this branch exists for exhaustive
                        // matching if the decision enum grows.
                        workerDone()
                        return
                    case let .retain(sensitivity, expiry, oneTime):
                        privacy = (sensitivity, expiry, oneTime)
                    }
                    let record = self.store.insert(
                        ClipStore.Insertion(
                            payload: payload,
                            kind: kind,
                            oversized: reduction.oversized,
                            byteSize: reduction.byteSize,
                            sourceBundleID: source.bundleIdentifier,
                            sourceName: source.localizedName,
                            prepared: prepared,
                            sensitivity: privacy.sensitivity,
                            expiry: privacy.expiry,
                            oneTime: privacy.oneTime
                        )
                    )
                    if reduction.oversized {
                        self.log.info("entry over the size cap; kept metadata only (\(reduction.byteSize) bytes)")
                    }
                    NotificationCenter.default.post(name: Self.historyChanged, object: nil)
                    completion?(record)
                    self.schedulePrivacyTimer()
                    workerDone()
                }
            }
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
        guard started, captureEnabled else { return nil }
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
        guard captureEnabled else {
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
        // Mach round trip for an integer. Capture is scheduled off-main; the panel can
        // show immediately and receives `historyChanged` when the row commits.
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
            let source = NSWorkspace.shared.frontmostApplication
                .map(ClipboardCaptureSource.init(application:)) ?? .unknown
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
                // We already recorded this change; stop the monitor recording it again.
                self.monitor.acceptCurrentAsSeen()
                self.scheduleCaptureFromPasteboard(source: source) { record in
                    guard let record else {
                        ClipboardHUD.shared.show(
                            "这条内容没有被记录", symbol: "eye.slash", style: .warning
                        )
                        return
                    }
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
                records: [record], merged: false, plainTextOnly: false, activating: nil,
                consumeOneTimeOnSuccess: ticket == nil
            ) { [weak self] result in
                guard let self else { return }
                var deliveredResult = result
                if let ticket {
                    if result.succeeded {
                        switch self.queue.commitDequeue(ticket) {
                        case .committed:
                            if record.oneTime {
                                self.permanentlyDeleteSensitiveRecords([record.id])
                            }
                            NotificationCenter.default.post(name: Self.queueChanged, object: nil)
                        case .failed(let failure):
                            deliveredResult = ClipboardOperationResult(
                                items: result.items,
                                failure: .eventDelivery(.queueCommit(failure)),
                                pasteboardChangeCount: result.pasteboardChangeCount,
                                restore: result.restore
                            )
                        }
                    } else {
                        self.queue.rollbackDequeue(ticket)
                    }
                }
                if !deliveredResult.succeeded { self.presentPasteFailure(deliveredResult) }
                completion?(deliveredResult)
                let remaining = self.queue.count
                if cameFromQueue, deliveredResult.succeeded, remaining > 0 {
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
        let pasteAs: PasteAsMode
        let app: NSRunningApplication?
        let transform: PasteTransform?
        let separator: String
        let restoreAfterPaste: Bool
        let consumeOneTimeOnSuccess: Bool
        let completion: ((ClipboardOperationResult) -> Void)?
    }

    private var pasteRequests: [PasteRequest] = []
    private var pasteInFlight = false

    /// The single path everything pastes through: place on the pasteboard, make sure
    /// the target application is frontmost, synthesize ⌘V, optionally put the previous
    /// clipboard back.
    ///
    /// `transform` is a text rewrite. It implies plain text — a rewritten body cannot be
    /// carried by the original RTF or HTML, and pretending otherwise would paste the
    /// untransformed styled half into anything that prefers it.
    @discardableResult
    func paste(
        records: [ClipRecord],
        merged: Bool,
        plainTextOnly: Bool,
        activating app: NSRunningApplication?,
        transform: PasteTransform? = nil,
        pasteAs: PasteAsMode? = nil,
        batchPolicy: ClipboardBatchPolicy = .allOrNothing,
        consumeOneTimeOnSuccess: Bool = true,
        completion: ((ClipboardOperationResult) -> Void)? = nil
    ) -> ClipboardOperationDispatch {
        let resolvedPasteAs = pasteAs ?? (plainTextOnly ? .plainText : .original)
        let requirement: PreflightPayloadRequirement = transform != nil
            || (merged && records.count > 1)
            ? .mergeableText
            : .pasteAs(resolvedPasteAs)
        switch preflight(records, requirement: requirement, batchPolicy: batchPolicy) {
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
                    prepared: prepared, merged: merged, pasteAs: resolvedPasteAs,
                    app: app, transform: transform, separator: settings.joinSeparator,
                    restoreAfterPaste: settings.restoreAfterPaste,
                    consumeOneTimeOnSuccess: consumeOneTimeOnSuccess,
                    completion: completion
                )
            )
            drainPasteRequests()
            return .scheduled
        }
    }

    private enum PreflightPayloadRequirement {
        case any
        case mergeableText
        case pasteAs(PasteAsMode)
    }

    private func preflight(
        _ records: [ClipRecord],
        requirement: PreflightPayloadRequirement = .any,
        batchPolicy: ClipboardBatchPolicy = .allOrNothing
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
        var validRecords: [ClipRecord] = []
        for record in records {
            if record.oversized {
                items.append(ClipboardItemResult(id: record.id, state: .failed(.oversized)))
                failed = true
            } else if let payload = store.payload(for: record.id) {
                let compatible: Bool
                switch requirement {
                case .any: compatible = true
                case .mergeableText: compatible = Paster.isMergeCompatible(payload)
                case .pasteAs(let mode): compatible = Paster.isCompatible(payload, as: mode)
                }
                if !compatible {
                    items.append(
                        ClipboardItemResult(
                            id: record.id,
                            state: .failedPreflight(.incompatiblePayload)
                        )
                    )
                    failed = true
                } else {
                    validRecords.append(record)
                    payloads.append(payload)
                    items.append(ClipboardItemResult(id: record.id, state: .ready))
                }
            } else {
                items.append(ClipboardItemResult(id: record.id, state: .failed(.missingPayload)))
                failed = true
            }
        }
        guard !failed || (batchPolicy == .skipInvalid && !validRecords.isEmpty) else {
            return .failure(
                ClipboardOperationResult(
                    items: items, failure: .preflightFailed, pasteboardChangeCount: nil,
                    restore: .notRequested
                )
            )
        }
        return .success(
            PreparedBatch(records: validRecords, payloads: payloads, itemResults: items)
        )
    }

    private func drainPasteRequests() {
        guard !pasteInFlight, !pasteRequests.isEmpty else { return }
        pasteInFlight = true
        let request = pasteRequests.removeFirst()

        // Every transaction owns an immediate rollback snapshot, irrespective of the
        // user's optional post-success restore preference. A previous delayed restore is
        // cancelled before placement so its token/work cannot fire into this transaction.
        let inheritedSuccessSnapshot = request.restoreAfterPaste ? pendingRestoreSnapshot : nil
        clearPendingRestore()
        let rollbackSnapshot = Paster.snapshot(pasteEnvironment.pasteboard)
        let successRestoreSnapshot = request.restoreAfterPaste
            ? (inheritedSuccessSnapshot ?? rollbackSnapshot)
            : nil

        let placement: Result<Paster.Placement, Paster.PlacementFailure>
        if let transform = request.transform {
            placement = Paster.placeTransformed(
                request.prepared.payloads, separator: request.separator, transform: transform,
                to: pasteEnvironment.pasteboard
            )
        } else if request.merged, request.prepared.payloads.count > 1 {
            placement = Paster.placeMerged(
                request.prepared.payloads, separator: request.separator,
                as: request.pasteAs,
                to: pasteEnvironment.pasteboard
            )
        } else {
            placement = Paster.place(
                request.prepared.payloads[0], as: request.pasteAs,
                to: pasteEnvironment.pasteboard
            )
        }

        guard case .success(let placed) = placement else {
            let failure: Paster.PlacementFailure
            if case .failure(let value) = placement { failure = value } else { fatalError() }
            let actualChangeCount = pasteEnvironment.pasteboard.changeCount
            let restore: ClipboardRestoreDisposition
            if actualChangeCount != rollbackSnapshot.changeCount {
                restore = .attempted(
                    restoreImmediately(
                        rollbackSnapshot, expectedChangeCount: actualChangeCount
                    )
                )
            } else {
                restore = .notRequested
            }
            finishPaste(
                request,
                result: ClipboardOperationResult(
                    items: request.prepared.itemResults,
                    failure: .pasteboardWrite(failure), pasteboardChangeCount: nil,
                    restore: restore
                )
            )
            return
        }
        monitor.ignore(changeCount: placed.changeCount)

        pasteEnvironment.activate(request.app) { [weak self] activation in
            guard let self else { return }
            guard activation == .ready else {
                let restore = self.restoreImmediately(
                    rollbackSnapshot, expectedChangeCount: placed.changeCount
                )
                self.finishPaste(
                    request,
                    result: ClipboardOperationResult(
                        items: request.prepared.itemResults, failure: .targetUnavailable,
                        pasteboardChangeCount: placed.changeCount,
                        restore: .attempted(restore)
                    )
                )
                return
            }

            // Accessibility can be revoked while an application is being activated.
            // Re-check at the last observable boundary before constructing/posting ⌘V.
            guard self.pasteEnvironment.accessibilityStatus() == .granted else {
                let restore = self.restoreImmediately(
                    rollbackSnapshot, expectedChangeCount: placed.changeCount
                )
                self.finishPaste(
                    request,
                    result: ClipboardOperationResult(
                        items: request.prepared.itemResults,
                        failure: .accessibilityPermissionDenied,
                        pasteboardChangeCount: placed.changeCount,
                        restore: .attempted(restore)
                    )
                )
                return
            }

            switch self.pasteEnvironment.sendPaste() {
            case .failure(let failure):
                let restore = self.restoreImmediately(
                    rollbackSnapshot, expectedChangeCount: placed.changeCount
                )
                self.finishPaste(
                    request,
                    result: ClipboardOperationResult(
                        items: request.prepared.itemResults,
                        failure: .eventDelivery(failure),
                        pasteboardChangeCount: placed.changeCount,
                        restore: .attempted(restore)
                    )
                )
            case .success:
                let delay = Paster.restoreDelay(
                    for: request.prepared.payloads,
                    targetActivationRequired: request.app != nil
                )
                self.scheduleRestoreIfNeeded(
                    successRestoreSnapshot, expectedChangeCount: placed.changeCount, delay: delay
                )
                self.finishPaste(
                    request,
                    result: ClipboardOperationResult(
                        items: self.completedItemResults(for: request.prepared),
                        failure: nil,
                        pasteboardChangeCount: placed.changeCount,
                        restore: successRestoreSnapshot == nil
                            ? .notRequested
                            : .scheduled(expectedChangeCount: placed.changeCount)
                    )
                )
            }
        }
    }

    private func finishPaste(_ request: PasteRequest, result: ClipboardOperationResult) {
        if !result.succeeded { presentPasteFailure(result) }
        if result.succeeded, request.consumeOneTimeOnSuccess {
            let consumed = request.prepared.records.compactMap { record in
                record.oneTime ? record.id : nil
            }
            permanentlyDeleteSensitiveRecords(consumed)
        }
        request.completion?(result)
        pasteInFlight = false
        drainPasteRequests()
    }

    private func completedItemResults(for prepared: PreparedBatch) -> [ClipboardItemResult] {
        let completedIDs = Set(prepared.records.map(\.id))
        return prepared.itemResults.map { item in
            guard completedIDs.contains(item.id), item.state == .ready else { return item }
            return ClipboardItemResult(id: item.id, state: .completed)
        }
    }

    private func scheduleRestoreIfNeeded(
        _ snapshot: Paster.PasteboardSnapshot?, expectedChangeCount: Int, delay: TimeInterval
    ) {
        guard let snapshot else { return }
        clearPendingRestore()
        let token = UUID()
        pendingRestoreToken = token
        pendingRestoreSnapshot = snapshot
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

    private func restoreImmediately(
        _ snapshot: Paster.PasteboardSnapshot, expectedChangeCount: Int
    ) -> Paster.RestoreResult {
        clearPendingRestore()
        let result = Paster.restore(
            snapshot, ifUnchangedSince: expectedChangeCount,
            to: pasteEnvironment.pasteboard
        )
        if case .restored(let changeCount) = result {
            monitor.ignore(changeCount: changeCount)
        }
        return result
    }

    private func clearPendingRestore() {
        pendingRestore?.cancel()
        pendingRestore = nil
        pendingRestoreToken = nil
        pendingRestoreSnapshot = nil
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
    func copyMerged(
        _ records: [ClipRecord],
        batchPolicy: ClipboardBatchPolicy = .allOrNothing
    ) -> ClipboardOperationResult {
        let requirement: PreflightPayloadRequirement = records.count > 1 ? .mergeableText : .any
        switch preflight(records, requirement: requirement, batchPolicy: batchPolicy) {
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
                items: completedItemResults(for: prepared),
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
