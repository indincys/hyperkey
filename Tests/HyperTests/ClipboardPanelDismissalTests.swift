import AppKit
import XCTest

@testable import Hyper

/// How long the panel takes to get out of the way once it has been clicked away from.
///
/// A click somewhere else reaches the panel as a resign *with the button still down*,
/// which is indistinguishable, at that instant, from a file being picked up in Finder on
/// its way here. So the panel waits for the release. What it must not do is wait any
/// longer than that: it used to sample the button every 0.06s and then hold a further
/// 0.3s for a drop to finish arriving, before fading out over another tenth — close to
/// half a second to dismiss a launcher, which is the "慢悠悠" these replaced.
///
/// The rule now: let go anywhere but over the panel and it is gone on the next frame,
/// because a drop cannot be delivered to a window the pointer is not on. Only a release
/// over the panel is owed the wait.
///
/// Nothing here races a stopwatch. The panel's own polling and the markers below are all
/// blocks on the main queue, which delivers them in deadline order — so "the panel went
/// before the marker fired" is an ordering, not a measurement.
final class ClipboardPanelDismissalTests: XCTestCase {
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
            "hyper-panel-dismissal-\(label)-\(UUID().uuidString)", isDirectory: true
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

    /// A pointer the test drives: a button, and a place.
    private final class Pointer {
        var down = false
        var location = NSPoint(x: -10_000, y: -10_000)
    }

    private func shownController(_ label: String, pointer: Pointer) -> ClipboardPanelController {
        let controller = ClipboardPanelController(manager: manager(label))
        controller.primaryButtonDown = { pointer.down }
        controller.pointerLocation = { pointer.location }
        controller.show()
        XCTAssertTrue(controller.isVisible)
        return controller
    }

    private func settle(_ predicate: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Fires once the main queue reaches a point `after` seconds from now.
    private func marker(after seconds: TimeInterval) -> () -> Bool {
        var fired = false
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { fired = true }
        return { fired }
    }

    // MARK: - A click

    /// The button is already up by the time the resign arrives — a tap on a trackpad.
    /// Nothing to wait for, and nothing left on screen when the call returns.
    func testAResignWithTheButtonUpClosesThePanelBeforeItReturns() {
        let pointer = Pointer()
        let controller = shownController("tap", pointer: pointer)

        controller.panelResignedKey()

        XCTAssertFalse(controller.isVisible, "closing is synchronous: no fade to sit through")
    }

    /// The ordinary click: down somewhere else, up in the same place.
    func testAClickSomewhereElseClosesThePanelAsSoonAsTheButtonComesUp() {
        let pointer = Pointer()
        let controller = shownController("click", pointer: pointer)
        defer { controller.hide() }

        pointer.down = true
        controller.panelResignedKey()
        XCTAssertTrue(controller.isVisible, "a button still down may be a drag on its way here")

        // Held for a while, the way a press is.
        let held = marker(after: 0.1)
        settle { held() }
        XCTAssertTrue(controller.isVisible, "the panel waits for the release, however long")

        pointer.down = false
        // The old path could not have closed before this: 0.06s to notice the release
        // and 0.3s of waiting for a drop that a click was never going to deliver.
        let tooLate = marker(after: 0.2)
        settle { !controller.isVisible }

        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(tooLate(), "a click elsewhere must not be held for a drop")
    }

    // MARK: - A drag

    /// Something really was dragged in and dropped on the list: the panel keeps its place
    /// and takes the keyboard back.
    func testAReleaseOverThePanelThatDeliveredADropKeepsItUp() throws {
        let pointer = Pointer()
        let controller = shownController("drop", pointer: pointer)
        defer { controller.hide() }
        let frame = try XCTUnwrap(controller.listFrame)

        pointer.down = true
        controller.panelResignedKey()

        pointer.location = NSPoint(x: frame.midX, y: frame.midY)
        pointer.down = false
        controller.model.noteDropCompleted()
        // Past the whole of the window a drop is given to arrive in.
        let decided = marker(after: 0.5)
        settle { decided() }

        XCTAssertTrue(controller.isVisible, "a drop the list took is why it stayed up")

        // And the exemption is over: the next click elsewhere closes it like any other.
        controller.panelResignedKey()
        XCTAssertFalse(controller.isVisible)
    }

    /// Released over the panel with nothing in hand — a selection dragged through another
    /// application's text and let go here. It brought nothing, so the resign stands.
    func testAReleaseOverThePanelThatDeliveredNothingStillCloses() throws {
        let pointer = Pointer()
        let controller = shownController("no-drop", pointer: pointer)
        defer { controller.hide() }
        let frame = try XCTUnwrap(controller.listFrame)

        pointer.down = true
        controller.panelResignedKey()

        pointer.location = NSPoint(x: frame.midX, y: frame.midY)
        pointer.down = false
        settle { !controller.isVisible }

        XCTAssertFalse(controller.isVisible, "an overheard drag that brought nothing keeps nothing up")
    }

    /// A drag let go anywhere off the panel cannot have been for it. No wait at all.
    func testADragReleasedAwayFromThePanelIsNotHeldForADrop() {
        let pointer = Pointer()
        let controller = shownController("drag-away", pointer: pointer)
        defer { controller.hide() }

        pointer.down = true
        controller.panelResignedKey()
        // Travelling, the way a drag does, and never over the list.
        pointer.location = NSPoint(x: -9_000, y: -9_500)
        let dragged = marker(after: 0.05)
        settle { dragged() }
        XCTAssertTrue(controller.isVisible)

        pointer.down = false
        let tooLate = marker(after: 0.2)
        settle { !controller.isVisible }

        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(tooLate(), "nothing can be dropped on a window the pointer is not over")
    }

    // MARK: - Typing

    /// The wait before a search is only there to fold a burst of keys into one. The
    /// search itself is cancellable and off the main thread, so anything longer is
    /// latency added to every answer.
    func testAKeystrokeIsNotHeldBackForLongerThanABurstTakes() {
        XCTAssertLessThanOrEqual(ClipboardPanelModel.searchDebounce, 0.05)
    }
}
