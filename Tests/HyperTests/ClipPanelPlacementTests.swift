import AppKit
import XCTest

@testable import Hyper

/// The panel's placement arithmetic, checked without a display.
///
/// The one property that matters is not cosmetic: in `.mouseRight` the panel must open
/// beside the pointer, never under it. A panel that lands on a row hovers that row on the
/// opening frame, which is exactly what the panel's `hoverArmed` guard exists to prevent —
/// so the geometry that avoids it is worth an assertion rather than an eyeball.
final class ClipPanelPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    private let size = NSSize(width: 400, height: 800)
    private let margin: CGFloat = 12
    private let gap: CGFloat = 10

    private func origin(
        _ mode: ClipPanelPosition, pointer: NSPoint, visible: NSRect? = nil, size: NSSize? = nil
    ) -> NSPoint {
        ClipPanelPlacement.origin(
            mode: mode,
            size: size ?? self.size,
            pointer: pointer,
            visible: visible ?? screen,
            screenMargin: margin,
            gap: gap
        )
    }

    /// The default: to the right of the pointer, top edge level with it.
    func testMouseRightOpensBesideThePointerNotUnderIt() {
        let pointer = NSPoint(x: 600, y: 1000)
        let placed = origin(.mouseRight, pointer: pointer)
        let frame = NSRect(origin: placed, size: size)

        XCTAssertGreaterThanOrEqual(frame.minX, pointer.x + gap, "the panel starts right of the pointer")
        XCTAssertEqual(frame.maxY, pointer.y, accuracy: 1, "the top edge is level with the pointer")
        XCTAssertFalse(frame.contains(pointer))
    }

    /// With no room to the right it flips to the left rather than sliding back under the
    /// cursor, and it still does not contain the pointer.
    func testMouseRightFlipsToTheLeftWhenTheScreenRunsOut() {
        let pointer = NSPoint(x: 1500, y: 700)
        let placed = origin(.mouseRight, pointer: pointer)
        let frame = NSRect(origin: placed, size: size)

        XCTAssertLessThanOrEqual(frame.maxX, pointer.x - gap)
        XCTAssertFalse(frame.contains(pointer))
        XCTAssertGreaterThanOrEqual(frame.minX, margin)
    }

    /// A pointer in the bottom-right corner, where the panel fits neither beside it nor
    /// below it: it must still be placed fully on screen.
    func testCrampedCornerStaysOnScreen() {
        let pointer = NSPoint(x: 1720, y: 8)
        let placed = origin(.mouseRight, pointer: pointer)
        let frame = NSRect(origin: placed, size: size)

        XCTAssertGreaterThanOrEqual(frame.minX, margin)
        XCTAssertGreaterThanOrEqual(frame.minY, margin)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - margin)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - margin)
    }

    /// A display shorter than the panel has no valid range to clamp into; the panel must
    /// still be anchored on screen rather than pushed off the bottom edge.
    func testAScreenShorterThanThePanelStillAnchorsOnScreen() {
        let short = NSRect(x: 0, y: 0, width: 1728, height: 600)
        let placed = origin(.mouseRight, pointer: NSPoint(x: 600, y: 300), visible: short)
        XCTAssertGreaterThanOrEqual(placed.y, margin)
    }

    func testMouseHangsBelowThePointerAndStaysCentred() {
        let pointer = NSPoint(x: 800, y: 900)
        let placed = origin(.mouse, pointer: pointer)
        let frame = NSRect(origin: placed, size: size)

        XCTAssertEqual(frame.midX, pointer.x, accuracy: 1)
        XCTAssertLessThanOrEqual(frame.maxY, pointer.y)
        XCTAssertFalse(frame.contains(pointer))
    }

    func testCenterIgnoresThePointer() {
        let a = origin(.center, pointer: NSPoint(x: 10, y: 10))
        let b = origin(.center, pointer: NSPoint(x: 1600, y: 1000))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.x, (screen.midX - size.width / 2).rounded())
    }

    func testBottomSitsNearTheBottomEdgeCentred() {
        let placed = origin(.bottom, pointer: NSPoint(x: 10, y: 1000))
        XCTAssertEqual(placed.y, (screen.minY + 24).rounded())
        XCTAssertEqual(placed.x, (screen.midX - size.width / 2).rounded())
    }

    /// Every mode, on every pointer position, keeps the whole panel inside the visible
    /// frame — including the corner positions where the naive arithmetic would put an
    /// edge off screen, and `.center`, whose 8% nudge used to hang the panel off the
    /// bottom on a display only a little taller than the panel.
    func testEveryModeStaysInsideTheVisibleFrame() {
        let visible = NSRect(x: 100, y: 50, width: 1200, height: 900)
        let corners = [
            NSPoint(x: 110, y: 60), NSPoint(x: 1290, y: 60),
            NSPoint(x: 110, y: 940), NSPoint(x: 1290, y: 940),
            NSPoint(x: 700, y: 450),
        ]
        for mode in ClipPanelPosition.allCases {
            for pointer in corners {
                let placed = origin(mode, pointer: pointer, visible: visible)
                let frame = NSRect(origin: placed, size: size)
                XCTAssertGreaterThanOrEqual(
                    frame.minX, visible.minX + margin, "\(mode) \(pointer)"
                )
                XCTAssertGreaterThanOrEqual(
                    frame.minY, visible.minY + margin, "\(mode) \(pointer)"
                )
                XCTAssertLessThanOrEqual(
                    frame.maxX, visible.maxX - margin, "\(mode) \(pointer)"
                )
                XCTAssertLessThanOrEqual(
                    frame.maxY, visible.maxY - margin, "\(mode) \(pointer)"
                )
            }
        }
    }

    /// `.center` is the one mode whose placement does not depend on the pointer, and the
    /// clamp must not have made it depend on one.
    func testCenterStaysCentredWhenThePanelFits() {
        let visible = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let placed = origin(.center, pointer: NSPoint(x: 10, y: 10), visible: visible)
        XCTAssertEqual(placed.x, (visible.midX - size.width / 2).rounded())
        XCTAssertGreaterThanOrEqual(placed.y, margin)
        XCTAssertLessThanOrEqual(placed.y + size.height, visible.maxY - margin)
    }

    /// The shipped default, so a config that predates the setting opens beside the
    /// pointer rather than jumping to the middle of the screen.
    func testTheDefaultPositionIsBesideThePointer() {
        XCTAssertEqual(ClipPanelPosition.fallback, .mouseRight)
        XCTAssertEqual(ClipboardSettings().panelPositionMode, .mouseRight)
    }
}
