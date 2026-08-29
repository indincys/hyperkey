import ApplicationServices
import Cocoa
import os

/// A return target is needed only while LaunchServices has not yet confirmed the
/// activation requested by Hyper. Once the target really reaches the front,
/// `previousFrontmostApplication` is the authoritative, up-to-date fallback.
struct PendingApplicationReturns<Key: Hashable, Application> {
    private var applications: [Key: Application] = [:]

    mutating func remember(_ application: Application, for key: Key) {
        applications[key] = application
    }

    mutating func confirmActivation(of key: Key) {
        applications.removeValue(forKey: key)
    }

    mutating func take(for key: Key) -> Application? {
        applications.removeValue(forKey: key)
    }
}

/// Launches, activates, or hides the application bound to a key.
///
/// Resolution runs off the event-tap callback: a LaunchServices lookup can take
/// milliseconds, and a slow tap callback gets the tap disabled by the system. The
/// decision and the action itself happen on the main thread.
final class AppLauncher {
    static let shared = AppLauncher()

    private let log = Logger(subsystem: Hyper.subsystem, category: "launcher")
    private let queue = DispatchQueue(label: "\(Hyper.subsystem).launcher", qos: .userInitiated)

    private struct Resolved {
        let url: URL
        let bundleID: String?
    }

    /// One press-and-hold application switch.
    ///
    /// Resolution and application launch are both asynchronous. Keeping the session
    /// after the physical chord has ended is intentional: a cold application can finish
    /// launching after the user has already released the keys, and without this state it
    /// would steal focus several hundred milliseconds after the peek was supposedly over.
    private struct PeekSession {
        let id: UUID
        let key: CGKeyCode
        let targetDescription: String
        let previousApplication: NSRunningApplication?
        var resolved: Resolved?
        var targetApplication: NSRunningApplication?
        var activationRequested = false
        var activationCompleted = false
        var ended = false
        var restorePrevious = true
        var shouldDismissTarget = true
    }

    /// Keyed by the raw config value. Touched only on `queue`.
    private var cache: [String: Resolved] = [:]

    /// What is in front, as far as we know. Main thread only.
    ///
    /// Activation is asynchronous, so asking `NSWorkspace` at the moment of a second
    /// keypress can still report the *previous* application — which is exactly the
    /// "hold hyper, tap the key twice to peek and go back" case. Updating this
    /// optimistically the instant we ask for activation makes the second press hide,
    /// and the workspace notification corrects it either way.
    private var frontmostBundleID: String?

    /// The workspace's confirmed activation history. This is also the fallback return
    /// destination when the target was already frontmost before Hyper saw the press.
    private var currentFrontmostApplication: NSRunningApplication?
    private var previousFrontmostApplication: NSRunningApplication?

    /// Where an app-switch request came from while its activation is still pending.
    ///
    /// A rapid second press can arrive before the workspace activation notification. In
    /// that narrow window, this preserves the application to use if hiding is refused.
    /// Confirmation removes the entry so it can never become a stale long-term return
    /// destination after the user switches applications by some other route.
    private var pendingReturnApplications =
        PendingApplicationReturns<String, NSRunningApplication>()

    /// Peek state is main-thread-only, like `frontmostBundleID`.
    private var peekSessions: [UUID: PeekSession] = [:]
    private var activePeekID: UUID?

    func updateFrontmost(_ application: NSRunningApplication?) {
        if let bundleID = application?.bundleIdentifier {
            pendingReturnApplications.confirmActivation(of: bundleID)
        }
        if let application,
           currentFrontmostApplication?.processIdentifier != application.processIdentifier {
            previousFrontmostApplication = currentFrontmostApplication
            currentFrontmostApplication = application
        } else if application == nil {
            currentFrontmostApplication = nil
        }
        frontmostBundleID = application?.bundleIdentifier
    }

    func activate(_ target: LaunchTarget, repeatPress: RepeatPress) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let resolved = self.resolve(target) else {
                self.log.error("cannot resolve target \(target.description, privacy: .public)")
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            DispatchQueue.main.async { self.perform(resolved, repeatPress: repeatPress) }
        }
    }

    /// Shows an application for exactly as long as a Hyper chord is held.
    ///
    /// Starting a second peek while the first key is still physically down replaces the
    /// first one and preserves the original return destination. This avoids building a
    /// fragile stack whose result would depend on which letter the user releases first.
    func beginPeek(_ target: LaunchTarget, key: CGKeyCode) {
        dispatchPrecondition(condition: .onQueue(.main))

        var previous = NSWorkspace.shared.frontmostApplication
        if let activePeekID, let active = peekSessions[activePeekID] {
            if active.key == key, !active.ended { return }
            previous = active.previousApplication
            requestPeekEnd(activePeekID, restorePrevious: false)
        }

        // A replacement peek returns to the application from before the whole gesture,
        // not to the first peek target. `requestPeekEnd` activates nothing in this path,
        // so the new target can take focus without an asynchronous fight in between.
        let id = UUID()
        peekSessions[id] = PeekSession(
            id: id,
            key: key,
            targetDescription: target.description,
            previousApplication: previous
        )
        self.activePeekID = id

        queue.async { [weak self] in
            guard let self else { return }
            let resolved = self.resolve(target)
            DispatchQueue.main.async { self.startPeek(id, resolved: resolved) }
        }
    }

    /// Ends a peek when its letter is released. A stale release from a replaced chord
    /// must not close the newer application, hence the key comparison.
    func endPeek(for key: CGKeyCode) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let id = activePeekID, peekSessions[id]?.key == key else { return }
        requestPeekEnd(id, restorePrevious: true)
    }

    /// Ends whichever peek is active when Hyper itself is released or tap state resets.
    func endActivePeek() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let id = activePeekID else { return }
        requestPeekEnd(id, restorePrevious: true)
    }

    func invalidateCache() {
        queue.async { self.cache.removeAll() }
    }

    private func perform(_ resolved: Resolved, repeatPress: RepeatPress) {
        let bundleID = resolved.bundleID

        if repeatPress != .none, let bundleID, frontmostBundleID == bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           !running.isHidden {
            switch repeatPress {
            case .hide:
                dismiss(running, bundleID: bundleID)
                return
            case .cycle:
                // A refusal from the accessibility API falls through to a plain
                // activation, which is harmless: the application is already in front.
                if cycleWindows(pid: running.processIdentifier, bundleID: bundleID) { return }
            case .peek, .none:
                break
            }
        }

        if let bundleID {
            let previous = NSWorkspace.shared.frontmostApplication
            if let previous, previous.bundleIdentifier != bundleID {
                pendingReturnApplications.remember(previous, for: bundleID)
            }
            frontmostBundleID = bundleID
        }

        openAndRaise(resolved) { [log] _, error in
            if let error {
                log.error("open failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    // The optimistic guess did not happen; fall back to the truth.
                    AppLauncher.shared.frontmostBundleID =
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                }
            }
        }
    }

    /// Hides a frontmost target like Raycast's Toggle Visibility action.
    ///
    /// A successful hide is the whole operation: macOS owns application ordering and
    /// reveals whichever application was most recently underneath. Some applications,
    /// notably Chrome, refuse `hide()`. Only then do we activate the most recently
    /// confirmed application as a compatibility fallback.
    private func dismiss(_ running: NSRunningApplication, bundleID: String) {
        let previous = pendingReturnApplications.take(for: bundleID) ?? {
            if let currentFrontmostApplication,
               currentFrontmostApplication.processIdentifier != running.processIdentifier {
                // Activation notifications can trail the optimistic target update.
                return currentFrontmostApplication
            }
            return previousFrontmostApplication
        }()
        let hideAccepted = running.hide()

        if hideAccepted {
            // Make another immediate press show the target again even if the workspace
            // notification for the application revealed by macOS has not arrived yet.
            frontmostBundleID = nil
            log.info("hidden \(bundleID, privacy: .public); using system application ordering")

            // An accepted request is normally reflected immediately, but verify because
            // a few applications acknowledge AppKit operations without applying them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, running, previous] in
                guard let self, !running.isTerminated else { return }
                let actual = NSWorkspace.shared.frontmostApplication
                guard !running.isHidden,
                      actual?.processIdentifier == running.processIdentifier
                else { return }

                self.log.error(
                    "hide verification failed for \(bundleID, privacy: .public); activating fallback"
                )
                self.activateFallback(previous, from: running, bundleID: bundleID)
            }
            return
        }

        log.error("hide refused for \(bundleID, privacy: .public); activating fallback")
        activateFallback(previous, from: running, bundleID: bundleID)
    }

    private func activateFallback(
        _ previous: NSRunningApplication?,
        from running: NSRunningApplication,
        bundleID: String
    ) {
        guard let previous,
              !previous.isTerminated,
              previous.processIdentifier != running.processIdentifier
        else {
            frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            log.error("could not hide \(bundleID, privacy: .public): no fallback application")
            NSSound.beep()
            return
        }

        let activationAccepted = previous.activate(options: [.activateAllWindows])
        frontmostBundleID = previous.bundleIdentifier
        log.info("fallback=\(previous.bundleIdentifier ?? "unknown", privacy: .public) activationAccepted=\(activationAccepted)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, previous] in
            guard let self, !previous.isTerminated else { return }
            let actual = NSWorkspace.shared.frontmostApplication
            guard actual?.processIdentifier != previous.processIdentifier else {
                self.log.info(
                    "return verified frontmost=\(previous.bundleIdentifier ?? "unknown", privacy: .public)"
                )
                return
            }

            guard let url = previous.bundleURL else {
                self.frontmostBundleID = actual?.bundleIdentifier
                self.log.error(
                    "return verification failed for \(previous.bundleIdentifier ?? "unknown", privacy: .public): no bundle URL"
                )
                return
            }

            self.openAndRaise(Resolved(url: url, bundleID: previous.bundleIdentifier)) {
                [weak self] application, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.frontmostBundleID =
                            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        self.log.error(
                            "return retry failed: \(error.localizedDescription, privacy: .public)"
                        )
                    } else {
                        self.frontmostBundleID = application?.bundleIdentifier
                        self.log.info(
                            "return retried via workspace app=\(application?.bundleIdentifier ?? "unknown", privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Hold to peek

    private func startPeek(_ id: UUID, resolved: Resolved?) {
        guard var session = peekSessions[id] else { return }
        guard let resolved else {
            log.error("cannot resolve peek target \(session.targetDescription, privacy: .public)")
            peekSessions[id] = nil
            if activePeekID == id { activePeekID = nil }
            NSSound.beep()
            return
        }

        // If the chord ended while LaunchServices was resolving the bundle, nothing has
        // been activated yet and there is nothing to undo. Most ordinary resolutions hit
        // the cache, but this makes a very fast tap deterministic even on a cold cache.
        guard !session.ended else {
            peekSessions[id] = nil
            return
        }

        session.resolved = resolved
        if let bundleID = resolved.bundleID {
            session.targetApplication = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first
            session.shouldDismissTarget =
                session.previousApplication?.bundleIdentifier != bundleID
            frontmostBundleID = bundleID
        } else if let previousURL = session.previousApplication?.bundleURL {
            session.shouldDismissTarget =
                previousURL.standardizedFileURL != resolved.url.standardizedFileURL
        }
        session.activationRequested = true
        peekSessions[id] = session

        openAndRaise(resolved) {
            [weak self] application, error in
            DispatchQueue.main.async {
                self?.peekActivationCompleted(id, application: application, error: error)
            }
        }
    }

    private func peekActivationCompleted(
        _ id: UUID, application: NSRunningApplication?, error: Error?
    ) {
        guard var session = peekSessions[id] else { return }
        session.activationCompleted = true
        if let application {
            session.targetApplication = application
            if session.previousApplication?.processIdentifier == application.processIdentifier {
                session.shouldDismissTarget = false
            }
        }
        peekSessions[id] = session

        if let error {
            log.error("peek open failed: \(error.localizedDescription, privacy: .public)")
            frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }

        // The common warm-app path gets here before the user releases the keys. A cold
        // app can get here afterwards; dismissing again here prevents its late activation
        // from jumping over the application we already restored.
        if session.ended {
            dismissPeek(session)
            peekSessions[id] = nil
        }
    }

    private func requestPeekEnd(_ id: UUID, restorePrevious: Bool) {
        guard var session = peekSessions[id], !session.ended else { return }
        session.ended = true
        session.restorePrevious = restorePrevious
        peekSessions[id] = session
        if activePeekID == id { activePeekID = nil }

        guard session.activationRequested else {
            // The resolver's main-thread callback will see that the session disappeared
            // and refrain from opening the application at all.
            peekSessions[id] = nil
            return
        }

        dismissPeek(session)
        if session.activationCompleted { peekSessions[id] = nil }
    }

    private func dismissPeek(_ session: PeekSession) {
        guard session.shouldDismissTarget else { return }

        // An older, slow launch must not hide a newer peek that targets the same app.
        let newerTargetsSameApplication: Bool = {
            guard let activePeekID, activePeekID != session.id,
                  let active = peekSessions[activePeekID], !active.ended else { return false }
            if let lhs = session.resolved?.bundleID, let rhs = active.resolved?.bundleID {
                return lhs == rhs
            }
            return session.targetDescription == active.targetDescription
        }()

        if !newerTargetsSameApplication {
            let target = session.targetApplication
                ?? session.resolved?.bundleID.flatMap {
                    NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
                }
            if let target, !target.isTerminated { target.hide() }
        }

        if session.restorePrevious {
            if let previous = session.previousApplication, !previous.isTerminated {
                previous.activate(options: [.activateAllWindows])
                frontmostBundleID = previous.bundleIdentifier
            } else {
                frontmostBundleID = nil
            }
        } else if let activePeekID,
                  let current = peekSessions[activePeekID]?.targetApplication,
                  !current.isTerminated {
            // A replaced cold launch may finish after the new peek is visible. Put the
            // current target back in front after hiding that stale application.
            current.activate(options: [.activateAllWindows])
            frontmostBundleID = current.bundleIdentifier
        }

        log.info("ended peek for \(session.targetDescription, privacy: .public)")
    }

    // MARK: - Application activation

    /// Gives an already-running application the same semantic nudge as a Dock click.
    ///
    /// `openApplication(... activates: true)` can make a process own the menu bar without
    /// ordering any of its windows forward. WeChat is a repeat offender: the menu changes
    /// to Weixin while the previous Chrome window remains visible and inactive. Raising
    /// every existing window covers windows that are merely behind another application;
    /// the reopen Apple event covers applications whose last visible window was closed.
    private func openAndRaise(
        _ resolved: Resolved,
        completion: @escaping (NSRunningApplication?, Error?) -> Void
    ) {
        let running = runningApplication(for: resolved)
        var runningProcessIdentifier: pid_t?
        if let running, !running.isTerminated {
            runningProcessIdentifier = running.processIdentifier
            let accepted = running.activate(options: [.activateAllWindows])
            log.info(
                "raised running app \(resolved.bundleID ?? resolved.url.lastPathComponent, privacy: .public) accepted=\(accepted)"
            )
        }

        let configuration = Self.activationConfiguration(
            runningProcessIdentifier: runningProcessIdentifier
        )
        NSWorkspace.shared.openApplication(
            at: resolved.url, configuration: configuration, completionHandler: completion
        )
    }

    private func runningApplication(for resolved: Resolved) -> NSRunningApplication? {
        if let bundleID = resolved.bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { !$0.isTerminated }
        }
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated
                && $0.bundleURL?.standardizedFileURL == resolved.url.standardizedFileURL
        }
    }

    /// Internal for the regression tests: a warm launch must carry a reopen event, while
    /// a cold launch must retain LaunchServices' normal open-application event.
    static func activationConfiguration(
        runningProcessIdentifier: pid_t?
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let pid = runningProcessIdentifier else { return configuration }

        let target = NSAppleEventDescriptor(processIdentifier: pid)
        configuration.appleEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        return configuration
    }

    // MARK: - Window cycling

    /// Raises the application's next window, rcmd-style.
    ///
    /// Returns false only when the accessibility API would not tell us enough to act, so
    /// the caller can fall back; a deliberate no-op (one window, nothing to cycle to)
    /// still returns true. No permission dance here — the event tap already requires
    /// accessibility trust, so if we are running at all, we have it.
    private func cycleWindows(pid: pid_t, bundleID: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // Every call below is synchronous on the main thread, and a target that has
        // stopped answering — spinning beachball, stopped in a debugger — would hold
        // each one for the accessibility default of six seconds. That is long enough
        // for the system to decide our event tap is too slow and switch it off, which
        // takes the whole hyper key down with it. An application that is answering at
        // all answers well inside 300ms; one that is not falls through to a plain
        // activation, which is what the caller does with a `false` anyway.
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            log.error("no window list for \(bundleID, privacy: .public)")
            return false
        }

        let candidates = windows.filter { window in
            if boolValue(window, kAXMinimizedAttribute) == true { return false }
            // Panels, sheets and popovers are not places to cycle to. But plenty of
            // ordinary windows answer nothing at all when asked for a subrole, so only a
            // window that positively claims to be something else is dropped.
            if let subrole = stringValue(window, kAXSubroleAttribute),
               subrole != kAXStandardWindowSubrole {
                return false
            }
            return true
        }
        guard candidates.count > 1 else { return true }

        // `main` is the one the application considers its document window; `focused`
        // covers applications that keep the two apart. Neither being set is odd but
        // survivable — start from the end so the first window is what comes next.
        let current = candidates.firstIndex { boolValue($0, kAXMainAttribute) == true }
            ?? candidates.firstIndex { boolValue($0, kAXFocusedAttribute) == true }
        let next = candidates[((current ?? candidates.count - 1) + 1) % candidates.count]

        guard AXUIElementPerformAction(next, kAXRaiseAction as CFString) == .success else {
            log.error("raise refused by \(bundleID, privacy: .public)")
            return false
        }
        // Raising orders the window in front; making it main is what moves the
        // application's own idea of "the current window", and with it the menu bar.
        AXUIElementSetAttributeValue(next, kAXMainAttribute as CFString, kCFBooleanTrue)

        let title = stringValue(next, kAXTitleAttribute) ?? "(untitled)"
        log.info("""
            cycled \(bundleID, privacy: .public) to \(title, privacy: .private) \
            (\(candidates.count, privacy: .public) windows)
            """)
        return true
    }

    private func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func resolve(_ target: LaunchTarget) -> Resolved? {
        let key = target.description
        if let hit = cache[key], FileManager.default.fileExists(atPath: hit.url.path) { return hit }

        let url: URL?
        switch target {
        case .path(let raw):
            let candidate = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            url = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        case .bundleID(let id):
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        case .action:
            // Built-in actions never reach here — `HyperTap` routes them itself.
            url = nil
        }

        guard let url else { return nil }
        let resolved = Resolved(url: url, bundleID: Bundle(url: url)?.bundleIdentifier)
        cache[key] = resolved
        return resolved
    }
}
