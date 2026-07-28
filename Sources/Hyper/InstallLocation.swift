import Cocoa
import os

/// Gets the app into `/Applications` before anything else happens.
///
/// This matters more than tidiness. Distribution is by `git clone`, so the app usually
/// starts life inside the cloned working tree — and updating in place there would write
/// into a git repository. Accessibility is also granted per bundle path, so moving after
/// the user has granted it would cost them a second trip to System Settings. Asking on
/// first launch, before the permission prompt, avoids both.
enum InstallLocation {
    private static let log = Logger(subsystem: Hyper.subsystem, category: "install")

    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Returns true if a move was performed (the app relaunches and this process exits).
    @discardableResult
    static func offerToMoveIfNeeded() -> Bool {
        guard !isInApplicationsFolder else { return false }
        // Running straight out of Xcode's build folder is a development detail, not
        // something to nag about.
        guard !Bundle.main.bundleURL.path.contains("/.build/") else { return false }

        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/\(source.lastPathComponent)")

        let alert = NSAlert()
        alert.messageText = "把 Hyper 移到「应用程序」文件夹？"
        alert.informativeText = """
        Hyper 现在的位置是：
        \(source.deletingLastPathComponent().path)

        放进「应用程序」文件夹后，自动更新才能正常工作，「辅助功能」授权也不会因为改变位置而失效。
        """
        alert.addButton(withTitle: "移动")
        alert.addButton(withTitle: "以后再说")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            log.info("user declined to move into /Applications")
            return false
        }

        do {
            try move(from: source, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "移动失败"
            failure.informativeText = """
            \(error.localizedDescription)

            可以手动把 Hyper.app 拖进「应用程序」文件夹，效果一样。
            """
            failure.alertStyle = .warning
            failure.runModal()
            return false
        }

        relaunch(at: destination)
        return true
    }

    private static func move(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "「应用程序」文件夹里已经有一个 Hyper"
            alert.informativeText = "要用当前这一份替换它吗？"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else {
                throw CocoaError(.userCancelled)
            }
            try fileManager.removeItem(at: destination)
        }

        // Copy rather than move: the source may sit inside a git working tree, and
        // leaving it in place keeps that checkout intact.
        try fileManager.copyItem(at: source, to: destination)
        log.info("copied app into /Applications")
    }

    /// Launches the copy at its new home, then exits so only one instance survives.
    private static func relaunch(at destination: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            if let error {
                log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
