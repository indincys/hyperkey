import AppKit
import XCTest

@testable import Hyper

/// The zoom transform, checked as arithmetic.
///
/// The property worth asserting is the one the feature is *for*: the point of the picture
/// under the pointer is the point that grows. Everything else — clamping the scale,
/// keeping the picture over the card, coming back to fit — is here because each of those
/// is a way for the anchored zoom to end up looking broken.
final class ClipImageZoomTests: XCTestCase {
    private let view = CGSize(width: 400, height: 300)
    private let image = CGSize(width: 800, height: 600)

    private func rect(_ zoom: ClipImageZoom) -> CGRect {
        zoom.drawnRect(viewSize: view, imageSize: image)
    }

    func testFitCentresThePictureAndFillsTheShorterAxis() {
        let zoom = ClipImageZoom()
        XCTAssertFalse(zoom.isZoomed)
        XCTAssertEqual(zoom.scale, 1)
        XCTAssertEqual(rect(zoom), CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    /// A picture whose proportion does not match the card is letterboxed by the fit,
    /// not stretched.
    func testFitKeepsProportionAndLetterboxesTheRest() {
        let zoom = ClipImageZoom()
        let drawn = zoom.drawnRect(
            viewSize: CGSize(width: 400, height: 400),
            imageSize: CGSize(width: 800, height: 200)
        )
        XCTAssertEqual(drawn.width, 400)
        XCTAssertEqual(drawn.height, 100)
        XCTAssertEqual(drawn.midX, 200)
        XCTAssertEqual(drawn.midY, 200, "the band is split evenly above and below")
    }

    func testZoomingAtTheCentreKeepsTheCentreFixed() {
        var zoom = ClipImageZoom()
        zoom.zoom(by: 2, at: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image)
        XCTAssertEqual(zoom.scale, 2)
        XCTAssertEqual(rect(zoom).midX, 200, accuracy: 0.001)
        XCTAssertEqual(rect(zoom).midY, 150, accuracy: 0.001)
    }

    /// The whole point of the feature.
    func testZoomingAtAPointKeepsThatPointOfThePictureUnderThePointer() {
        var zoom = ClipImageZoom()
        // A quarter across and a third up, deliberately off-centre and off-axis.
        let anchor = CGPoint(x: 100, y: 100)
        let before = rect(zoom)
        let fractionX = (anchor.x - before.minX) / before.width
        let fractionY = (anchor.y - before.minY) / before.height

        zoom.zoom(by: 3, at: anchor, viewSize: view, imageSize: image)

        let after = rect(zoom)
        XCTAssertEqual(after.minX + fractionX * after.width, anchor.x, accuracy: 0.001)
        XCTAssertEqual(after.minY + fractionY * after.height, anchor.y, accuracy: 0.001)
    }

    /// And it stays true through a sequence of scrolls, which is how it is actually used:
    /// each event re-anchors on where the pointer is *now*.
    func testRepeatedZoomsEachHoldTheirOwnAnchor() {
        var zoom = ClipImageZoom()
        for (index, anchor) in [
            CGPoint(x: 120, y: 80), CGPoint(x: 260, y: 200), CGPoint(x: 200, y: 150),
        ].enumerated() {
            let before = rect(zoom)
            let fractionX = min(max((anchor.x - before.minX) / before.width, 0), 1)
            let fractionY = min(max((anchor.y - before.minY) / before.height, 0), 1)
            zoom.zoom(by: 1.4, at: anchor, viewSize: view, imageSize: image)
            let after = rect(zoom)
            XCTAssertEqual(
                after.minX + fractionX * after.width, anchor.x, accuracy: 0.001,
                "scroll \(index) lost its anchor"
            )
            XCTAssertEqual(
                after.minY + fractionY * after.height, anchor.y, accuracy: 0.001,
                "scroll \(index) lost its anchor"
            )
        }
        XCTAssertGreaterThan(zoom.scale, 1)
    }

    func testScaleIsClampedToItsRange() {
        var zoom = ClipImageZoom()
        for _ in 0..<40 {
            zoom.zoom(by: 2, at: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image)
        }
        XCTAssertEqual(zoom.scale, ClipImageZoom.maxScale)
        XCTAssertEqual(rect(zoom).width, 400 * ClipImageZoom.maxScale, accuracy: 0.001)

        for _ in 0..<80 {
            zoom.zoom(by: 0.5, at: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image)
        }
        XCTAssertEqual(zoom.scale, ClipImageZoom.minScale)
        XCTAssertFalse(zoom.isZoomed)
        XCTAssertEqual(rect(zoom).midX, 200, accuracy: 0.001)
        XCTAssertEqual(rect(zoom).midY, 150, accuracy: 0.001)
    }

    /// Zoomed in, the picture covers the card: no band of empty glass can be pulled into
    /// the middle of it by zooming towards a corner.
    func testZoomedPictureCoversTheCard() {
        var zoom = ClipImageZoom()
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 300)] {
            zoom = ClipImageZoom()
            for _ in 0..<10 {
                zoom.zoom(by: 2, at: corner, viewSize: view, imageSize: image)
            }
            let drawn = rect(zoom)
            XCTAssertLessThanOrEqual(drawn.minX, 0.001, "corner \(corner)")
            XCTAssertLessThanOrEqual(drawn.minY, 0.001, "corner \(corner)")
            XCTAssertGreaterThanOrEqual(drawn.maxX, view.width - 0.001, "corner \(corner)")
            XCTAssertGreaterThanOrEqual(drawn.maxY, view.height - 0.001, "corner \(corner)")
        }
    }

    /// The pointer in the letterbox band is still inside the view, and zooming there must
    /// pull that edge of the picture towards it rather than losing the anchor entirely.
    func testZoomingFromTheLetterboxBandStaysOnScreen() {
        var zoom = ClipImageZoom()
        let wide = CGSize(width: 800, height: 200)
        zoom.zoom(
            by: 4, at: CGPoint(x: 200, y: 10),
            viewSize: CGSize(width: 400, height: 400), imageSize: wide
        )
        let drawn = zoom.drawnRect(
            viewSize: CGSize(width: 400, height: 400), imageSize: wide
        )
        XCTAssertGreaterThan(drawn.width, 0)
        XCTAssertEqual(drawn.midX, 200, accuracy: 0.001, "a mismatched axis stays centred")
        XCTAssertLessThanOrEqual(drawn.minY, 0.001)
        XCTAssertGreaterThanOrEqual(drawn.maxY, 400 - 0.001)
    }

    func testResetReturnsToFit() {
        var zoom = ClipImageZoom()
        zoom.zoom(by: 4, at: CGPoint(x: 40, y: 280), viewSize: view, imageSize: image)
        XCTAssertTrue(zoom.isZoomed)

        zoom.reset()
        XCTAssertFalse(zoom.isZoomed)
        XCTAssertEqual(zoom.scale, 1)
        XCTAssertEqual(zoom.offset, .zero)
        XCTAssertEqual(rect(zoom), CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    // MARK: - Moving around

    /// Panning has to leave the magnification exactly where it was: it is how the detail
    /// away from where the pointer first landed is reached, not a second way to zoom.
    func testPanSlidesThePictureWithoutChangingTheScale() {
        var zoom = ClipImageZoom()
        zoom.zoom(by: 4, at: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image)
        let before = rect(zoom)
        let scale = zoom.scale

        zoom.pan(by: CGSize(width: -50, height: 30), viewSize: view, imageSize: image)

        let after = rect(zoom)
        XCTAssertEqual(zoom.scale, scale)
        XCTAssertEqual(after.minX, before.minX - 50, accuracy: 0.001)
        XCTAssertEqual(after.minY, before.minY + 30, accuracy: 0.001)
    }

    /// A drag past the edge stops at the edge: the picture covers the card rather than
    /// sliding off it and leaving a band of glass.
    func testPanIsClampedSoThePictureStillCoversTheCard() {
        var zoom = ClipImageZoom()
        zoom.zoom(by: 3, at: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image)

        for delta in [CGSize(width: 1000, height: 1000), CGSize(width: -1000, height: -1000)] {
            zoom.pan(by: delta, viewSize: view, imageSize: image)
            let drawn = rect(zoom)
            XCTAssertLessThanOrEqual(drawn.minX, 0.001)
            XCTAssertLessThanOrEqual(drawn.minY, 0.001)
            XCTAssertGreaterThanOrEqual(drawn.maxX, view.width - 0.001)
            XCTAssertGreaterThanOrEqual(drawn.maxY, view.height - 0.001)
        }
    }

    /// Every part of a zoomed picture is reachable: pushed to each of the four extremes
    /// in turn, each edge of the picture lines up with the matching edge of the card.
    func testEveryEdgeOfThePictureCanBeReached() {
        var zoom = ClipImageZoom()
        zoom.zoom(by: 3, at: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image)
        let drawn = rect(zoom)

        zoom.pan(by: CGSize(width: 0, height: drawn.height), viewSize: view, imageSize: image)
        XCTAssertEqual(rect(zoom).minY, 0, accuracy: 0.001, "the bottom edge is reachable")
        zoom.pan(by: CGSize(width: 0, height: -2 * drawn.height), viewSize: view, imageSize: image)
        XCTAssertEqual(rect(zoom).maxY, view.height, accuracy: 0.001, "the top edge is reachable")
        zoom.pan(by: CGSize(width: drawn.width, height: 0), viewSize: view, imageSize: image)
        XCTAssertEqual(rect(zoom).minX, 0, accuracy: 0.001, "the left edge is reachable")
        zoom.pan(by: CGSize(width: -2 * drawn.width, height: 0), viewSize: view, imageSize: image)
        XCTAssertEqual(rect(zoom).maxX, view.width, accuracy: 0.001, "the right edge is reachable")
    }

    /// There is nothing to move while the whole picture is already visible.
    func testPanDoesNothingAtFit() {
        var zoom = ClipImageZoom()
        zoom.pan(by: CGSize(width: 80, height: -60), viewSize: view, imageSize: image)
        XCTAssertEqual(zoom.offset, .zero)
    }

    /// A picture letterboxed on one axis stays centred on that axis however it is
    /// dragged — moving it there would only reveal the letterbox.
    func testPanDoesNotMoveAnAxisThatIsNotLargerThanTheCard() {
        var zoom = ClipImageZoom()
        // Wider than the card and, once zoomed, exactly as tall as it: the vertical axis
        // has no slack to give.
        let wide = CGSize(width: 800, height: 200)
        let tall = CGSize(width: 400, height: 400)
        zoom.zoom(by: 4, at: CGPoint(x: 300, y: 200), viewSize: tall, imageSize: wide)
        XCTAssertNotEqual(zoom.offset.width, 0, "the horizontal axis has slack")

        zoom.pan(by: CGSize(width: 0, height: 300), viewSize: tall, imageSize: wide)

        XCTAssertEqual(zoom.offset.height, 0, accuracy: 0.001)
        XCTAssertNotEqual(zoom.offset.width, 0)
    }

    /// A degenerate size — a card laid out before the picture has arrived — must not
    /// produce a NaN transform that poisons every later computation.
    func testDegenerateSizesProduceNoTransform() {
        var zoom = ClipImageZoom()
        XCTAssertEqual(
            ClipImageZoom.fittedSize(imageSize: .zero, in: view), .zero
        )
        XCTAssertEqual(
            ClipImageZoom.fittedSize(imageSize: image, in: .zero), .zero
        )
        zoom.zoom(by: 2, at: .zero, viewSize: .zero, imageSize: image)
        XCTAssertEqual(zoom.scale, 1)
        zoom.zoom(by: .nan, at: .zero, viewSize: view, imageSize: image)
        XCTAssertEqual(zoom.scale, 1)
        zoom.zoom(by: 0, at: .zero, viewSize: view, imageSize: image)
        XCTAssertEqual(zoom.scale, 1)
    }
}

/// The view's lifecycle: what drops the zoom, and what deliberately does not.
final class ClipZoomableImageViewTests: XCTestCase {
    private func makeView() -> ClipZoomableImageView {
        let view = ClipZoomableImageView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.image = Self.picture(width: 800, height: 600)
        view.recordID = UUID()
        return view
    }

    private static func picture(width: Int, height: Int) -> NSImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, count: Int = 1, at point: CGPoint = CGPoint(x: 100, y: 100)
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: count, pressure: 0
        )!
    }

    func testZoomingThenLeavingThePictureResetsIt() {
        let view = makeView()
        view.applyZoom(factor: 2, at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(view.zoomState.isZoomed)

        view.pointerDidExit()

        XCTAssertFalse(view.zoomState.isZoomed)
        XCTAssertEqual(view.zoomState.scale, 1)
        XCTAssertEqual(view.zoomState.offset, .zero)
    }

    /// The requirement in the negative: a small movement *inside* the picture is not
    /// leaving it, so it must not throw the zoom away. Only the tracking area's exit —
    /// `pointerDidExit`, asserted above — crosses that line.
    func testMovingThePointerWithinThePictureDoesNotResetIt() {
        let view = makeView()
        view.applyZoom(factor: 2, at: CGPoint(x: 100, y: 100))

        for _ in 0..<5 {
            view.mouseMoved(with: mouseEvent(.mouseMoved))
        }

        XCTAssertTrue(view.zoomState.isZoomed, "the zoom has to survive a twitchy hand")
        XCTAssertEqual(view.zoomState.scale, 2)
    }

    func testMovingToAnotherEntryResetsIt() {
        let view = makeView()
        view.applyZoom(factor: 3, at: CGPoint(x: 200, y: 150))
        XCTAssertTrue(view.zoomState.isZoomed)

        view.recordID = UUID()

        XCTAssertFalse(view.zoomState.isZoomed)
    }

    /// The larger decode replacing the placeholder is the *same* entry, so a zoom made
    /// while the soft preview was up must survive the sharper one arriving.
    func testReplacingThePictureForTheSameEntryKeepsTheZoom() {
        let view = makeView()
        let recordID = view.recordID
        view.applyZoom(factor: 2.5, at: CGPoint(x: 120, y: 90))

        view.image = Self.picture(width: 1600, height: 1200)
        view.recordID = recordID

        XCTAssertTrue(view.zoomState.isZoomed)
        XCTAssertEqual(view.zoomState.scale, 2.5)
    }

    func testDoubleClickResetsAndASingleClickDoesNot() {
        let view = makeView()
        view.applyZoom(factor: 2, at: CGPoint(x: 100, y: 100))

        view.mouseDown(with: mouseEvent(.leftMouseDown, count: 1))
        XCTAssertTrue(view.zoomState.isZoomed, "one click is not a reset")

        view.mouseDown(with: mouseEvent(.leftMouseDown, count: 2))
        XCTAssertFalse(view.zoomState.isZoomed)
    }

    /// The panel is a floating non-activating window, so every click into it is a first
    /// mouse click — one the view would otherwise never be offered.
    func testTheViewAcceptsFirstMouse() {
        XCTAssertTrue(makeView().acceptsFirstMouse(for: nil))
    }

    /// The owner is told when the zoom becomes visible and when it goes away, and not
    /// once per scroll event while the number on the badge would be unchanged.
    func testZoomChangesAreCoalescedBeforeReachingTheOwner() {
        let view = makeView()
        var reports: [(Bool, CGFloat)] = []
        view.onZoomChange = { reports.append(($0, $1)) }

        // Five events, each below the half-percent the badge rounds at: nothing to show.
        for _ in 0..<5 {
            view.applyZoom(factor: 1.0005, at: CGPoint(x: 200, y: 150))
        }
        XCTAssertTrue(reports.isEmpty, "no visible change, no report")

        view.applyZoom(factor: 2, at: CGPoint(x: 200, y: 150))
        XCTAssertEqual(reports.count, 1, "five nudges and one real zoom are two states")
        XCTAssertEqual(reports.first?.0, true)
        XCTAssertGreaterThan(reports.first?.1 ?? 0, 1.9)

        view.pointerDidExit()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.last?.0, false)
    }

    /// Zooming needs a picture; before one has decoded there is nothing to scale.
    func testZoomingWithoutAPictureDoesNothing() {
        let view = ClipZoomableImageView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.applyZoom(factor: 2, at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(view.zoomState.scale, 1)
    }

    // MARK: - Dragging to move around

    /// The gesture the user asked for: once zoomed, dragging moves the view over the
    /// picture at the magnification already chosen.
    func testDraggingPansTheZoomedPictureAtTheSameMagnification() {
        let view = makeView()
        view.applyZoom(factor: 4, at: CGPoint(x: 200, y: 150))
        let before = view.zoomState.offset
        let scale = view.zoomState.scale

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 150)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 170, y: 120)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 170, y: 120)))

        XCTAssertNotEqual(view.zoomState.offset, before, "the picture has to have moved")
        XCTAssertEqual(view.zoomState.scale, scale, "moving is not zooming")
    }

    /// The picture follows the pointer rather than running away from it: dragging up and
    /// to the left moves the content up and to the left.
    func testThePictureFollowsTheDrag() {
        let view = makeView()
        view.applyZoom(factor: 4, at: CGPoint(x: 200, y: 150))
        let before = view.zoomState.offset

        // Up and to the left on screen. This view is not flipped, so y counts up: the
        // pointer going up is a larger y, and the content has to go up with it.
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 150)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 180, y: 170)))

        XCTAssertLessThan(view.zoomState.offset.width, before.width)
        XCTAssertGreaterThan(view.zoomState.offset.height, before.height)
    }

    func testDraggingDoesNothingWhileTheWholePictureIsVisible() {
        let view = makeView()
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 150)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 100, y: 80)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 100, y: 80)))
        XCTAssertEqual(view.zoomState.offset, .zero)
    }

    /// A double-click is still a reset, and must not be mistaken for the end of a drag
    /// that moved the picture somewhere unexpected on its way.
    func testDoubleClickStillResetsAfterDragging() {
        let view = makeView()
        view.applyZoom(factor: 3, at: CGPoint(x: 200, y: 150))
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 150)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 150, y: 120)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 150, y: 120)))
        XCTAssertTrue(view.zoomState.isZoomed)

        view.mouseDown(with: mouseEvent(.leftMouseDown, count: 2, at: CGPoint(x: 150, y: 120)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, count: 2, at: CGPoint(x: 150, y: 120)))

        XCTAssertFalse(view.zoomState.isZoomed)
        XCTAssertEqual(view.zoomState.offset, .zero)
    }

    /// Panning changes what is on screen, not how far in the picture is, so it must not
    /// churn the badge's number.
    func testPanningDoesNotReportAZoomChange() {
        let view = makeView()
        view.applyZoom(factor: 4, at: CGPoint(x: 200, y: 150))
        var reports = 0
        view.onZoomChange = { _, _ in reports += 1 }

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 150)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 160, y: 120)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 160, y: 120)))

        XCTAssertEqual(reports, 0)
    }

    // MARK: - Sensitivity

    /// One notch of an ordinary wheel used to be worth 221%. It has to be roughly half
    /// that now — the whole point of the change.
    func testOneWheelNotchNoLongerJumpsTheWholeRange() {
        let factor = ClipZoomableImageView.zoomFactor(scrollingDeltaY: 8, precise: false)
        XCTAssertGreaterThan(factor, 1.3, "the wheel still has to do something")
        XCTAssertLessThan(factor, 1.6, "and not cross most of the range in one notch")
        XCTAssertLessThan(factor, 2.21, "meaningfully gentler than the version that shipped")
    }

    /// A trackpad flick and a wheel notch should feel the same; the two devices report
    /// their deltas in different units and used to need constants that did not match.
    func testATrackpadFlickAndAWheelNotchFeelAlike() {
        let wheel = ClipZoomableImageView.zoomFactor(scrollingDeltaY: 8, precise: false)
        let trackpad = ClipZoomableImageView.zoomFactor(scrollingDeltaY: 66, precise: true)
        XCTAssertEqual(wheel, trackpad, accuracy: 0.02)
    }

    /// Whatever a device claims, one event can only move the zoom by a step a person can
    /// follow — a violent flick must not land at the top of the range.
    func testOneEventCanNeverJumpTheZoom() {
        for delta in [CGFloat(1000), CGFloat(-1000)] {
            let factor = ClipZoomableImageView.zoomFactor(
                scrollingDeltaY: delta, precise: false
            )
            XCTAssertLessThanOrEqual(factor, 1.5)
            XCTAssertGreaterThanOrEqual(factor, 1 / 1.5)
        }
    }

    func testANonScrollEventLeavesTheZoomAlone() {
        XCTAssertEqual(
            ClipZoomableImageView.zoomFactor(scrollingDeltaY: 0, precise: false), 1
        )
    }
}
