import AppKit
import XCTest

@testable import Hyper

/// The rubber band's claim on a ⌘-press, and giving the press back when it was only a
/// click.
///
/// The regression this exists for: `hitTest` claims every ⌘-left-mouse-down so the band
/// can track a drag, which is unavoidable — the press has to be ours before it is known
/// whether it becomes a drag. But nothing handed a press that never travelled back, so
/// ⌘-clicking a picture in a contact sheet did nothing at all. The panel's 连续粘贴
/// therefore worked on rows and text and files and stopped working on exactly the entries
/// it is most used for. Worse, the press cleared the multi-selection on its way past.
final class GridMarqueeHitTests: XCTestCase {
    private let width: CGFloat = 356
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil }
        windows.removeAll()
        super.tearDown()
    }

    /// The view in a real window, because `convert(_:from:nil)` — which is how both
    /// `hitTest` and `mouseDown` read a point — is meaningless without one, and the view
    /// is flipped so the conversion is not the identity.
    private func makeView(count: Int = 6) -> GridMarqueeNSView {
        let metrics = ImageGridMetrics(width: width, count: count)
        let view = GridMarqueeNSView()
        view.metrics = metrics
        view.range = 10..<(10 + count)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: metrics.totalHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = view
        windows.append(window)
        return view
    }

    private func metrics(count: Int = 6) -> ImageGridMetrics {
        ImageGridMetrics(width: width, count: count)
    }

    /// The centre of a cell, in the view's own coordinates.
    private func centre(of offset: Int, count: Int = 6) -> CGPoint {
        let frame = metrics(count: count).frame(of: offset)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// A mouse event for a point given in the view's coordinates, which is the space the
    /// tests reason in and not the space `NSEvent` is built in.
    private func event(
        _ type: NSEvent.EventType, in view: GridMarqueeNSView, at local: CGPoint,
        command: Bool = true, count: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(local, to: nil),
            modifierFlags: command ? [.command] : [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: count, pressure: 0
        )!
    }

    /// A real scroll event. `NSEvent.mouseEvent` and `otherEvent` both refuse
    /// `.scrollWheel`; only a `CGEvent` can make one, which is also what the window
    /// server actually delivers.
    private func scrollEvent(command: Bool = true) -> NSEvent {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cg = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel,
            wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0
        )!
        if command { cg.flags = .maskCommand }
        return NSEvent(cgEvent: cg)!
    }

    // MARK: - Which press is claimed

    func testTheMarqueeClaimsACommandPressAndNothingElse() {
        let view = makeView()
        let point = centre(of: 0)

        view.currentEvent = { self.event(.leftMouseDown, in: view, at: point, command: true) }
        XCTAssertTrue(view.hitTest(point) === view, "a ⌘-press is the band's")

        view.currentEvent = { self.event(.leftMouseDown, in: view, at: point, command: false) }
        XCTAssertNil(view.hitTest(point), "a plain press belongs to the cell")

        view.currentEvent = { self.event(.rightMouseDown, in: view, at: point, command: true) }
        XCTAssertNil(view.hitTest(point), "a right-click must still reach the context menu")

        view.currentEvent = { self.scrollEvent() }
        XCTAssertNil(view.hitTest(point), "the wheel must still scroll the list")

        view.currentEvent = { nil }
        XCTAssertNil(view.hitTest(point))
    }

    // MARK: - The regression

    /// A ⌘-press that comes up without travelling activates the entry under the pointer,
    /// in the indices the rest of the panel uses.
    func testACommandClickWithoutADragActivatesTheEntryUnderThePointer() {
        let view = makeView()
        var clicked: [Int] = []
        var cleared = 0
        view.onClick = { clicked.append($0) }
        view.onClear = { cleared += 1 }

        let point = centre(of: 1)
        view.mouseDown(with: event(.leftMouseDown, in: view, at: point))
        view.mouseUp(with: event(.leftMouseUp, in: view, at: point))

        XCTAssertEqual(clicked, [11], "offset 1 of a sheet starting at 10 is entry 11")
        XCTAssertEqual(cleared, 0, "a click is a paste, not a band — it must not clear the selection")
    }

    /// The click that must not work is the one the user did not make: a press that moved
    /// is a band, and activating a row as well would paste something on every marquee.
    func testADragDoesNotAlsoActivateARow() {
        let view = makeView()
        var clicked: [Int] = []
        var selected: [CGRect] = []
        var cleared = 0
        view.onClick = { clicked.append($0) }
        view.onSelect = { selected.append($0) }
        view.onClear = { cleared += 1 }

        let start = centre(of: 0)
        let end = centre(of: 4)
        view.mouseDown(with: event(.leftMouseDown, in: view, at: start))
        view.mouseDragged(with: event(.leftMouseDragged, in: view, at: end))
        view.mouseUp(with: event(.leftMouseUp, in: view, at: end))

        XCTAssertTrue(clicked.isEmpty, "a marquee must not paste")
        XCTAssertFalse(selected.isEmpty, "the band has to have been reported")
        XCTAssertEqual(cleared, 1, "and it clears the selection once, when it starts")
    }

    /// A hand that moves a point or two while clicking is still a click. Three points is
    /// the same threshold `MultiFileDragNSView` uses for the same reason.
    func testATinyMovementIsStillAClick() {
        let view = makeView()
        var clicked: [Int] = []
        view.onClick = { clicked.append($0) }
        let point = centre(of: 2)

        view.mouseDown(with: event(.leftMouseDown, in: view, at: point))
        view.mouseDragged(with: event(.leftMouseDragged, in: view, at: CGPoint(x: point.x + 2, y: point.y + 1)))
        view.mouseUp(with: event(.leftMouseUp, in: view, at: point))

        XCTAssertEqual(clicked, [12], "a shaky click is still a click")
    }

    /// A press in the gap between two cells names nothing, and must not guess.
    func testAPressInAGapActivatesNothing() {
        let view = makeView()
        var clicked: [Int] = []
        var selected: [CGRect] = []
        view.onClick = { clicked.append($0) }
        view.onSelect = { selected.append($0) }

        let first = metrics().frame(of: 0)
        let gap = CGPoint(x: first.maxX + 2, y: first.midY)
        XCTAssertNil(metrics().offset(at: gap), "the gap is not a cell")

        view.mouseDown(with: event(.leftMouseDown, in: view, at: gap))
        view.mouseUp(with: event(.leftMouseUp, in: view, at: gap))

        XCTAssertTrue(clicked.isEmpty)
        XCTAssertTrue(selected.isEmpty)
    }

    /// A click past the last cell of a part-full last line names nothing either.
    func testAPressPastTheLastCellActivatesNothing() {
        let view = makeView(count: 5)
        var clicked: [Int] = []
        view.onClick = { clicked.append($0) }

        // The sixth slot of a five-cell sheet, in the second row.
        let last = ImageGridMetrics(width: width, count: 5).frame(of: 4)
        let empty = CGPoint(x: last.maxX + 40, y: last.midY)
        XCTAssertNil(ImageGridMetrics(width: width, count: 5).offset(at: empty))

        view.mouseDown(with: event(.leftMouseDown, in: view, at: empty))
        view.mouseUp(with: event(.leftMouseUp, in: view, at: empty))

        XCTAssertTrue(clicked.isEmpty)
    }

    /// Every cell of a sheet is reachable by name, which is what makes the click land on
    /// the picture the pointer is actually over.
    func testEveryCellIsNamedByItsOwnCentre() {
        let count = 7
        let metrics = ImageGridMetrics(width: width, count: count)
        for offset in 0..<count {
            let frame = metrics.frame(of: offset)
            XCTAssertEqual(
                metrics.offset(at: CGPoint(x: frame.midX, y: frame.midY)), offset,
                "cell \(offset)"
            )
        }
    }

    /// The band's own bookkeeping is reset by a click, so the next ⌘-drag is not
    /// mistaken for a continuation of it.
    func testAClickLeavesNoBandStateBehind() {
        let view = makeView()
        var selected: [CGRect] = []
        view.onSelect = { selected.append($0) }
        let point = centre(of: 0)

        view.mouseDown(with: event(.leftMouseDown, in: view, at: point))
        view.mouseUp(with: event(.leftMouseUp, in: view, at: point))
        XCTAssertTrue(selected.isEmpty)

        // A drag afterwards still reports its band from scratch.
        view.mouseDown(with: event(.leftMouseDown, in: view, at: point))
        view.mouseDragged(with: event(.leftMouseDragged, in: view, at: centre(of: 2)))
        view.mouseUp(with: event(.leftMouseUp, in: view, at: centre(of: 2)))
        XCTAssertFalse(selected.isEmpty, "the click must not have broken the band")
    }
}
