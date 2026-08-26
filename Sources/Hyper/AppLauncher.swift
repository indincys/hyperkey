import ApplicationServices
import Cocoa
import os

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

    func updateFrontmost(_ bundleID: String?) {
        frontmostBundleID = bundleID
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
                running.hide()
                // Hiding hands focus to whatever comes next; let the workspace notification
                // tell us what that turned out to be rather than guessing.
                frontmostBundleID = nil
                log.info("hid \(bundleID, privacy: .public)")
                return
            case .cycle:
                // A refusal from the accessibility API falls through to a plain
                // activation, which is harmless: the application is already in front.
                if cycleWindows(pid: running.processIdentifier, bundleID: bundleID) { return }
            case .none:
                break
            }
        }

        if let bundleID { frontmostBundleID = bundleID }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: resolved.url, configuration: configuration) { [log] _, error in
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

    // MARK: - Window cycling

    /// Raises the application's next window, rcmd-style.
    ///
    /// Returns false only when the accessibility API would not tell us enough to act, so
    /// the caller can fall back; a deliberate no-op (one window, nothing to cycle to)
    /// still returns true. No permission dance here — the event tap already requires
    /// accessibility trust, so if we are running at all, we have it.
    private func cycleWindows(pid: pid_t, bundleID: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
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
