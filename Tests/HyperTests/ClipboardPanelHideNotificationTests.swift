import AppKit
import XCTest

@testable import Hyper

/// The panel closes itself along paths the manager never asked for — Escape, a completed
/// paste, losing key — and until `didHide` existed the polling backstop only found out at
/// its next 1.5s sample, staying at the fast watching rate in between. These pin the one
/// contract the manager relies on: exactly one callback per real disappearance, none for
/// a panel that was never up, and no ownership cycle from installing it.
final class ClipboardPanelHideNotificationTests: XCTestCase {
    private var roots: [URL] = []
    private var managers: [ClipboardManager] = []

    override func tearDown() {
        managers.removeAll()
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots.removeAll()
        super.tearDown()
    }

    private func manager(_ label: String) -> ClipboardManager {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-panel-hide-\(label)-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(location)
        let store = ClipStore(root: location)
        let loaded = expectation(description: "store loaded")
        let filters = expectation(description: "smart filters loaded")
        store.whenLoaded { loaded.fulfill() }
        store.whenSmartFiltersLoaded { filters.fulfill() }
        wait(for: [loaded, filters], timeout: 10)
        let queue = PasteQueue(storeURL: location.appendingPathComponent("queue.json"))
        queue.restore()
        let manager = ClipboardManager(store: store, queue: queue)
        managers.append(manager)
        return manager
    }

    func testHidingAVisiblePanelReportsItExactlyOnce() {
        let controller = ClipboardPanelController(manager: manager("visible"))
        var hides = 0
        controller.didHide = { hides += 1 }

        controller.show()
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(hides, 0, "showing must not report a hide")

        controller.hide(animated: false)
        XCTAssertEqual(hides, 1, "a panel leaving the screen must tell the poller once")

        // A second close of an already-closed panel is not a second disappearance.
        controller.hide(animated: false)
        XCTAssertEqual(hides, 1)

        // And the next appearance is reported again.
        controller.show()
        controller.hide(animated: false)
        XCTAssertEqual(hides, 2)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// `stop()` and the defensive closes call `hide()` on a controller that never had a
    /// window. Reporting those would be noise, not information.
    func testHidingAPanelThatWasNeverShownReportsNothing() {
        let controller = ClipboardPanelController(manager: manager("never-shown"))
        var hides = 0
        controller.didHide = { hides += 1 }

        controller.hide(animated: false)
        controller.prewarm()
        controller.hide(animated: false)

        XCTAssertEqual(hides, 0)
        XCTAssertFalse(controller.isVisible)
    }

    /// The manager owns the controller, so the closure it installs has to capture weakly.
    /// A strong capture here would keep both alive forever.
    func testInstallingTheCallbackDoesNotRetainTheController() {
        weak var released: ClipboardPanelController?
        autoreleasepool {
            var owner: ClipboardManager? = manager("cycle")
            var controller: ClipboardPanelController? = ClipboardPanelController(
                manager: owner!
            )
            released = controller
            controller?.didHide = { [weak controller] in _ = controller?.isVisible }
            controller?.prewarm()
            controller?.hide(animated: false)
            controller = nil
            managers.removeAll { $0 === owner }
            owner = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertNil(released, "the hide callback must not create an ownership cycle")
    }
}
