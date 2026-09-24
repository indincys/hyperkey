import Cocoa
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel

    init(delegate: AppDelegate) {
        model = SettingsModel(delegate: delegate)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hyper 设置"
        window.center()
        // The controller is held by the app delegate; closing must not deallocate it.
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        model.reload()
        // An accessory app has no Dock icon, so it has to ask for activation explicitly
        // or the window opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        // A miniaturised window is the same dead end as no window at all — there is no Dock
        // icon to click and no menu bar item to point at when the status item is hidden,
        // and `makeKeyAndOrderFront` leaves a minimised window minimised.
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// The config file changed underneath us (hand edit, or the menu bar toggle).
    func configDidChangeExternally() {
        guard window?.isVisible == true else { return }
        model.reload()
    }

    /// Permission or tap state changed; flips the onboarding screen over to the real
    /// settings the moment access is granted.
    func refreshStatus() {
        model.refreshStatus()
    }
}
