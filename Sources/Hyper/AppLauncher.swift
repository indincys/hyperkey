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

    func activate(_ target: LaunchTarget, toggle: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let resolved = self.resolve(target) else {
                self.log.error("cannot resolve target \(target.description, privacy: .public)")
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            DispatchQueue.main.async { self.perform(resolved, toggle: toggle) }
        }
    }

    func invalidateCache() {
        queue.async { self.cache.removeAll() }
    }

    private func perform(_ resolved: Resolved, toggle: Bool) {
        let bundleID = resolved.bundleID

        if toggle, let bundleID, frontmostBundleID == bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           !running.isHidden {
            running.hide()
            // Hiding hands focus to whatever comes next; let the workspace notification
            // tell us what that turned out to be rather than guessing.
            frontmostBundleID = nil
            log.info("hid \(bundleID, privacy: .public)")
            return
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
        }

        guard let url else { return nil }
        let resolved = Resolved(url: url, bundleID: Bundle(url: url)?.bundleIdentifier)
        cache[key] = resolved
        return resolved
    }
}
