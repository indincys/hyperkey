import AppKit
import Foundation
import os

/// Provenance captured before a clipboard read begins.
///
/// A polling change has no trustworthy owning process, so it is represented as
/// `.unknown` rather than being attributed to whichever application happens to be
/// frontmost when the timer eventually runs.
struct ClipboardCaptureSource: Equatable {
    enum Attribution: Equatable {
        case copyKeystroke
        case unknown
    }

    let processIdentifier: Int32?
    let bundleIdentifier: String?
    let localizedName: String?
    let attribution: Attribution

    static let unknown = ClipboardCaptureSource(
        processIdentifier: nil,
        bundleIdentifier: nil,
        localizedName: nil,
        attribution: .unknown
    )

    init(
        processIdentifier: Int32?,
        bundleIdentifier: String?,
        localizedName: String?,
        attribution: Attribution
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.attribution = attribution
    }

    init(application: NSRunningApplication) {
        self.init(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            attribution: .copyKeystroke
        )
    }
}

/// Notices that the system pasteboard changed.
///
/// macOS provides no notification for this — no KVO, no `NSNotification`, nothing. The
/// only public signal is `NSPasteboard.changeCount`, an integer that increments on
/// every write, so every clipboard manager on the platform polls it. This one polls
/// too, but less than most, because it has a signal the others do not:
///
///   * **Event driven, normally.** `HyperTap` already sees every keystroke on the
///     machine. A ⌘C or ⌘X there calls `checkSoon()`, and the new content is picked up
///     within a few tens of milliseconds — faster than any polling interval.
///   * **Slow polling as backstop.** Copies that never touch the keyboard — the Edit
///     menu, a right-click "Copy", an application writing to the pasteboard on its
///     own — have no keystroke to hang off. A timer catches those. Reading
///     `changeCount` is one Mach round trip returning an integer; it copies no data
///     and does not touch the payload.
///   * **The backstop adapts.** 1.5s normally; 0.3s while the history panel is open,
///     which is the only moment a missed poll-only copy is visible as a wrong answer;
///     3s after a minute of stillness and 5s after ten, so an unattended machine is not
///     woken forty times a minute to read an integer that has not moved. See `Cadence`.
///
/// The timer stops entirely while the screen is locked or the machine is asleep.
final class ClipboardMonitor {
    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.monitor")

    /// Backstop cadence, as a pure function of the two things that actually matter: is
    /// the user looking at the history right now, and how long has the pasteboard been
    /// still. Extracted so the policy can be asserted directly rather than inferred from
    /// timer behaviour.
    enum Cadence {
        /// The panel is open. Its list is the one place a missed poll-only copy is
        /// visible as a wrong answer, so this is the only state that polls quickly.
        static let watching: TimeInterval = 0.3
        /// Panel hidden, pasteboard recently active.
        static let base: TimeInterval = 1.5
        /// Nothing copied for `idleThreshold`.
        static let idle: TimeInterval = 3
        /// Nothing copied for `dormantThreshold` — a machine left alone.
        static let dormant: TimeInterval = 5

        static let idleThreshold: TimeInterval = 60
        static let dormantThreshold: TimeInterval = 600

        /// A copy resets the clock, so any change returns the cadence to its base rate.
        static func interval(
            panelVisible: Bool, secondsSinceLastChange: TimeInterval
        ) -> TimeInterval {
            if panelVisible { return watching }
            let idleFor = max(0, secondsSinceLastChange)
            if idleFor >= dormantThreshold { return dormant }
            if idleFor >= idleThreshold { return idle }
            return base
        }
    }

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suspended = false

    /// Current backstop interval, recomputed whenever the panel's visibility or the
    /// pasteboard's activity changes. A fixed 1.5s woke the CPU forty times a minute on
    /// a machine nobody was copying anything on, and was simultaneously too slow for the
    /// one moment it matters — the panel being open.
    private var pollInterval: TimeInterval = Cadence.base
    private var panelVisible = false
    private var panelVisibility: (() -> Bool)?
    private var lastChangeAt: Date

    private struct PendingCopySource {
        let source: ClipboardCaptureSource
        /// A normal pasteboard transaction increments once. Binding provenance to that
        /// exact count prevents a later, unrelated mutation from borrowing the source.
        let expectedChangeCount: Int
        let expiresAt: Date
    }

    /// A copy-key snapshot is only a candidate for the exact next transaction while
    /// the same application remains active. Poll-only changes never consume it as
    /// provenance; they are explicitly unknown.
    private var pendingCopySource: PendingCopySource?
    /// Invalidates delayed `checkSoon` closures across stop/restart and destruction.
    private var scheduledCheckGeneration: UInt64 = 0
    private let pendingSourceLifetime: TimeInterval = 0.75
    private let activeApplication: () -> ClipboardCaptureSource?
    private let now: () -> Date
    private var applicationActivationObserver: NSObjectProtocol?

    /// Change counts produced by our own writes. Paste puts content on the pasteboard
    /// as a matter of course; recording that as a fresh copy would fill the history
    /// with echoes of itself.
    private var ignoredChangeCounts = Set<Int>()

    /// Fired on the main thread when the pasteboard has genuinely changed.
    var onChange: ((ClipboardCaptureSource) -> Void)?

    init(
        pasteboard: NSPasteboard = .general,
        activeApplication: @escaping () -> ClipboardCaptureSource? = {
            NSWorkspace.shared.frontmostApplication.map(ClipboardCaptureSource.init(application:))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.activeApplication = activeApplication
        self.now = now
        lastChangeCount = pasteboard.changeCount
        lastChangeAt = now()
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.applicationDidChange(
                to: application.map(ClipboardCaptureSource.init(application:))
            )
        }
    }

    deinit {
        timer?.invalidate()
        scheduledCheckGeneration &+= 1
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        // The idle clock restarts with the timer. Without this, a machine that slept for
        // an hour — or a capture pause that lasted one — resumed straight into the 5s
        // dormant rate, exactly when the user is most likely to be copying again.
        lastChangeAt = now()
        pollInterval = desiredInterval()
        scheduleTimer()
        log.info("clipboard monitor started (backstop \(self.pollInterval, format: .fixed(precision: 1))s)")
    }

    /// Tells the monitor whether the history panel is on screen. An open panel is the one
    /// state where a poll-only copy has to appear promptly; everything else can back off.
    func setPanelVisible(_ visible: Bool) {
        if visible {
            // Opening the panel is also the moment to close the blind window, not just
            // the moment to speed the timer up.
            check()
        }
        guard panelVisible != visible else { return }
        panelVisible = visible
        applyCadence()
    }

    /// A standing answer to "is the panel up?", consulted on every tick.
    ///
    /// The panel closes itself along several paths — Escape, a completed paste, losing
    /// key — and requiring each of them to report in would eventually miss one and leave
    /// the monitor polling four times a second forever. Sampling instead means the worst
    /// case is one extra fast tick after a close.
    func trackPanelVisibility(_ provider: @escaping () -> Bool) {
        panelVisibility = provider
    }

    /// The interval this monitor would use right now. Exposed for lifecycle tests.
    var currentPollInterval: TimeInterval { pollInterval }

    private func desiredInterval() -> TimeInterval {
        Cadence.interval(
            panelVisible: panelVisible,
            secondsSinceLastChange: now().timeIntervalSince(lastChangeAt)
        )
    }

    /// Reschedules only when the rate actually moves, so a hidden panel's steady state
    /// costs one `changeCount` read per tick and nothing else.
    private func applyCadence() {
        let desired = desiredInterval()
        guard desired != pollInterval else { return }
        pollInterval = desired
        guard timer != nil else { return }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.check()
            // Re-evaluated on the tick rather than from a second timer: crossing the
            // idle and dormant thresholds is only interesting when we were about to
            // poll anyway.
            if let panelVisibility = self.panelVisibility {
                self.panelVisible = panelVisibility()
            }
            self.applyCadence()
        }
        // A little slack lets the system coalesce this with other timers instead of
        // waking the CPU on its own schedule.
        timer.tolerance = pollInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingCopySource = nil
        scheduledCheckGeneration &+= 1
        log.info("clipboard monitor stopped")
    }

    var isRunning: Bool { timer != nil }

    /// Pauses polling without forgetting where we were — used for lock and sleep.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        stop()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        // `start()` deliberately baselines the current change count. Check first so the
        // last copy made while the display was locked or the machine was asleep is not
        // silently accepted as that new baseline and lost forever.
        check()
        start()
    }

    // MARK: - Checking

    private func noteActivity() {
        lastChangeAt = now()
        applyCadence()
    }

    /// Called from the event tap right after a copy keystroke. Two checks: one almost
    /// immediately, one a little later for applications that put the data on the
    /// pasteboard asynchronously.
    @discardableResult
    func checkSoon(source: ClipboardCaptureSource) -> Int {
        // A copy keystroke is activity whether or not the pasteboard transaction has
        // landed yet, so an application that writes slowly still finds a warm cadence.
        noteActivity()
        let expectedChangeCount = pasteboard.changeCount &+ 1
        pendingCopySource = PendingCopySource(
            source: source,
            expectedChangeCount: expectedChangeCount,
            expiresAt: now().addingTimeInterval(pendingSourceLifetime)
        )
        let generation = scheduledCheckGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard self?.scheduledCheckGeneration == generation else { return }
            self?.check(expectedChangeCount: expectedChangeCount)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard self?.scheduledCheckGeneration == generation else { return }
            self?.check(expectedChangeCount: expectedChangeCount)
        }
        return expectedChangeCount
    }

    func check(
        source explicitSource: ClipboardCaptureSource? = nil,
        expectedChangeCount: Int? = nil
    ) {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        // Any transaction at all — including our own writes, which mean the user is
        // actively pasting — is evidence the machine is in use. Back up to the base rate.
        noteActivity()

        if ignoredChangeCounts.remove(current) != nil {
            pendingCopySource = nil
            log.info("skipping change \(current) — this one was our own write")
            return
        }

        let source: ClipboardCaptureSource
        if let explicitSource {
            source = explicitSource
        } else if let expectedChangeCount,
                  let pending = pendingCopySource,
                  pending.expectedChangeCount == expectedChangeCount,
                  current == expectedChangeCount,
                  now() <= pending.expiresAt,
                  sameApplication(activeApplication(), pending.source) {
            source = pending.source
        } else {
            source = .unknown
        }
        pendingCopySource = nil
        onChange?(source)
    }

    /// Flushes or invalidates the pending copy at the application-activation boundary.
    ///
    /// If the expected pasteboard transaction is already visible, it necessarily
    /// happened before this activation notification and still belongs to the old
    /// snapshot. If no transaction is visible, the old app's unused Cmd-C/Cmd-X loses
    /// its claim immediately; a later menu/right-click copy is reported as unknown.
    func applicationDidChange(to newApplication: ClipboardCaptureSource?) {
        guard let pending = pendingCopySource else { return }
        guard !sameApplication(newApplication, pending.source) else { return }
        let current = pasteboard.changeCount

        guard current != lastChangeCount else {
            pendingCopySource = nil
            log.info("discarded pending copy source after application activation without a pasteboard change")
            return
        }

        lastChangeCount = current
        noteActivity()
        let source: ClipboardCaptureSource
        if current == pending.expectedChangeCount, now() <= pending.expiresAt {
            source = pending.source
        } else {
            source = .unknown
        }
        pendingCopySource = nil

        if ignoredChangeCounts.remove(current) != nil {
            log.info("skipping change \(current) — this one was our own write")
            return
        }
        onChange?(source)
    }

    private func sameApplication(
        _ active: ClipboardCaptureSource?,
        _ snapshotted: ClipboardCaptureSource
    ) -> Bool {
        guard let active else { return false }
        if let activePID = active.processIdentifier,
           let snapshottedPID = snapshotted.processIdentifier {
            return activePID == snapshottedPID
        }
        guard let activeBundleID = active.bundleIdentifier,
              let snapshottedBundleID = snapshotted.bundleIdentifier else { return false }
        return activeBundleID == snapshottedBundleID
    }

    /// Marks a change count as ours. `NSPasteboard.clearContents()` returns the count
    /// the write will land on, so the caller knows the exact number to suppress and no
    /// guessing or time window is involved.
    func ignore(changeCount: Int) {
        ignoredChangeCounts.insert(changeCount)
        // Bounded: a missed suppression must not leak forever.
        if ignoredChangeCounts.count > 32 {
            ignoredChangeCounts = Set(ignoredChangeCounts.sorted().suffix(8))
        }
    }

    /// Brings our idea of the change count up to date without recording anything.
    func acceptCurrentAsSeen() {
        lastChangeCount = pasteboard.changeCount
        pendingCopySource = nil
    }

    /// Backoff schedule for `waitForChange`. A fixed 20ms retry spent the whole 600ms
    /// budget at the same rate whether the copy landed immediately or never came; the
    /// first two probes now catch the common fast case sooner, and a copy that is not
    /// coming costs a quarter of the wake-ups.
    private static let waitBackoff: [TimeInterval] = [0.01, 0.02, 0.04]

    /// Waits for the pasteboard to change, for at most `timeout`. Used after
    /// synthesizing a ⌘C: the copy is asynchronous and there is no completion to hook.
    func waitForChange(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        let baseline = pasteboard.changeCount
        var attemptIndex = 0

        func attempt() {
            if pasteboard.changeCount != baseline {
                completion(true)
                return
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            let delay = Self.waitBackoff[min(attemptIndex, Self.waitBackoff.count - 1)]
            attemptIndex += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { attempt() }
        }
        attempt()
    }
}
