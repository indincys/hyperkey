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

    /// The next pasteboard mutation after a real copy key belongs to the application
    /// snapshotted by the tap. It expires quickly: a copy command that produced no data
    /// must not lend its identity to an unrelated later menu copy.
    private var pendingSource: ClipboardCaptureSource?
    private var pendingSourceExpiresAt = Date.distantPast
    private let pendingSourceLifetime: TimeInterval = 0.75

    /// Change counts produced by our own writes. Paste puts content on the pasteboard
    /// as a matter of course; recording that as a fresh copy would fill the history
    /// with echoes of itself.
    private var ignoredChangeCounts = Set<Int>()

    /// Fired on the main thread when the pasteboard has genuinely changed.
    var onChange: ((ClipboardCaptureSource) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
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
        pendingSource = nil
        pendingSourceExpiresAt = .distantPast
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
    func checkSoon(source: ClipboardCaptureSource) {
        pendingSource = source
        pendingSourceExpiresAt = Date().addingTimeInterval(pendingSourceLifetime)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.check() }
    }

    func check(source explicitSource: ClipboardCaptureSource? = nil) {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if ignoredChangeCounts.remove(current) != nil {
            log.info("skipping change \(current) — this one was our own write")
            return
        }

        let source: ClipboardCaptureSource
        if let explicitSource {
            source = explicitSource
        } else if Date() <= pendingSourceExpiresAt, let pendingSource {
            source = pendingSource
        } else {
            source = .unknown
        }
        pendingSource = nil
        pendingSourceExpiresAt = .distantPast
        onChange?(source)
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
