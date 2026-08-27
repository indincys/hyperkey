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
///     own — have no keystroke to hang off. A 1.5s timer catches those. Reading
///     `changeCount` is one Mach round trip returning an integer; it copies no data
///     and does not touch the payload.
///
/// The timer stops entirely while the screen is locked or the machine is asleep.
final class ClipboardMonitor {
    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.monitor")

    /// Backstop interval. Deliberately slower than the 0.5s most clipboard managers
    /// use, because the keystroke path already covers the common case.
    private let pollInterval: TimeInterval = 1.5

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suspended = false

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
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        // A little slack lets the system coalesce this with other timers instead of
        // waking the CPU on its own schedule.
        timer.tolerance = pollInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.info("clipboard monitor started (backstop \(self.pollInterval, format: .fixed(precision: 1))s)")
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
        start()
        // Something may have been copied while we were not looking.
        check()
    }

    // MARK: - Checking

    /// Called from the event tap right after a copy keystroke. Two checks: one almost
    /// immediately, one a little later for applications that put the data on the
    /// pasteboard asynchronously.
    @discardableResult
    func checkSoon(source: ClipboardCaptureSource) -> Int {
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

    /// Waits for the pasteboard to change, for at most `timeout`. Used after
    /// synthesizing a ⌘C: the copy is asynchronous and there is no completion to hook.
    func waitForChange(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        let baseline = pasteboard.changeCount

        func attempt() {
            if pasteboard.changeCount != baseline {
                completion(true)
                return
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt() }
        }
        attempt()
    }
}
