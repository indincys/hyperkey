import AppKit
import SwiftUI

/// The transform a previewed picture is drawn with, as plain values.
///
/// Kept apart from the view so the part that is actually easy to get wrong — zooming
/// *towards the pointer* rather than towards the middle of the card — can be asserted
/// without standing an AppKit view up. The view supplies its bounds and the picture's
/// size; everything here is arithmetic on those.
///
/// The transform is scale-about-a-point plus a pan, not a rectangle: `scale` is how much
/// larger than "fit the card" the picture is, and `offset` is how far its centre has been
/// pushed from the card's. Both are in view points, so the picture's aspect ratio and the
/// card's never enter the state itself.
struct ClipImageZoom: Equatable {
    /// Fit. Not a limit that can be scrolled past: a preview smaller than the card is
    /// the card's own letterboxing, and zooming out past it would only shrink the picture
    /// into a stamp surrounded by glass.
    static let minScale: CGFloat = 1

    /// Far enough to read the pixels of a screenshot, and no further. Past this the
    /// picture is more interpolation than image, and 「在预览程序打开」 is the honest
    /// answer.
    static let maxScale: CGFloat = 8

    private(set) var scale: CGFloat = minScale
    private(set) var offset: CGSize = .zero

    /// Whether the picture is larger than its fit. The one thing the card's badge and the
    /// status line have to ask.
    var isZoomed: Bool { scale > Self.minScale + 0.0001 }

    /// Back to fit, centred. What leaving the picture and changing entries both do.
    mutating func reset() {
        scale = Self.minScale
        offset = .zero
    }

    /// The size the picture is drawn at with no zoom: as large as fits the card, keeping
    /// its own proportion.
    static func fittedSize(imageSize: CGSize, in viewSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else { return .zero }
        let factor = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
    }

    /// Where the picture lands in the view, in view coordinates.
    func drawnRect(viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let fitted = Self.fittedSize(imageSize: imageSize, in: viewSize)
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        let center = CGPoint(
            x: viewSize.width / 2 + offset.width,
            y: viewSize.height / 2 + offset.height
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Multiplies the scale by `factor`, holding the picture under `anchor` still.
    ///
    /// This is the whole feature: the point of the picture the pointer is on is the point
    /// that grows, so finding the detail you want to look at is one gesture instead of
    /// zoom-then-hunt. `anchor` is a point in view coordinates.
    mutating func zoom(
        by factor: CGFloat, at anchor: CGPoint, viewSize: CGSize, imageSize: CGSize
    ) {
        guard factor > 0, factor.isFinite else { return }
        let current = drawnRect(viewSize: viewSize, imageSize: imageSize)
        guard current.width > 0, current.height > 0 else { return }

        let next = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard abs(next - scale) > 0.0001 else { return }

        // Where the anchor sits *within the picture*, as a fraction of it. Clamped, so
        // zooming with the pointer in the card's letterbox band pulls that edge of the
        // picture towards the pointer instead of past it.
        let fractionX = min(max((anchor.x - current.minX) / current.width, 0), 1)
        let fractionY = min(max((anchor.y - current.minY) / current.height, 0), 1)

        scale = next
        let fitted = Self.fittedSize(imageSize: imageSize, in: viewSize)
        let size = CGSize(width: fitted.width * next, height: fitted.height * next)
        // Solve for the centre that puts the same fraction of the picture back under the
        // anchor.
        let center = clampCenter(
            CGPoint(
                x: anchor.x + (0.5 - fractionX) * size.width,
                y: anchor.y + (0.5 - fractionY) * size.height
            ),
            drawn: size, viewSize: viewSize
        )
        offset = CGSize(
            width: center.x - viewSize.width / 2,
            height: center.y - viewSize.height / 2
        )
    }

    /// Keeps the zoomed picture over the card.
    ///
    /// Along an axis the picture already fills, its edges are not allowed inside the
    /// card's — otherwise a zoom towards a corner, or a drag past the edge, would pull a
    /// band of empty glass into the middle of the picture. Along an axis it does not
    /// fill, it stays centred, which is the letterbox the fit already had.
    private func clampCenter(_ center: CGPoint, drawn: CGSize, viewSize: CGSize) -> CGPoint {
        let limitX = max(0, (drawn.width - viewSize.width) / 2)
        let limitY = max(0, (drawn.height - viewSize.height) / 2)
        return CGPoint(
            x: min(max(center.x, viewSize.width / 2 - limitX), viewSize.width / 2 + limitX),
            y: min(max(center.y, viewSize.height / 2 - limitY), viewSize.height / 2 + limitY)
        )
    }

    /// Slides the zoomed picture by `delta` view points.
    ///
    /// The scale does not change: moving around a picture you have zoomed into is how the
    /// detail away from where you first pointed is reached, and it has to stay at the
    /// magnification you chose. The clamp above is what stops a drag from running the
    /// picture off the card.
    mutating func pan(by delta: CGSize, viewSize: CGSize, imageSize: CGSize) {
        guard isZoomed, delta != .zero else { return }
        let fitted = Self.fittedSize(imageSize: imageSize, in: viewSize)
        guard fitted.width > 0, fitted.height > 0 else { return }
        let drawn = CGSize(
            width: fitted.width * scale, height: fitted.height * scale
        )
        let center = clampCenter(
            CGPoint(
                x: viewSize.width / 2 + offset.width + delta.width,
                y: viewSize.height / 2 + offset.height + delta.height
            ),
            drawn: drawn, viewSize: viewSize
        )
        offset = CGSize(
            width: center.x - viewSize.width / 2,
            height: center.y - viewSize.height / 2
        )
    }
}

/// The picture, drawn with the zoom above, and the gestures that drive it.
///
/// A real `NSView` rather than a SwiftUI gesture, because SwiftUI has no scroll-wheel or
/// magnify gesture and inventing one out of a `DragGesture` would lose the wheel entirely.
/// The view is also what makes "hold the point under the pointer" possible: only here is
/// the pointer's position in the same coordinates as the drawn rectangle.
final class ClipZoomableImageView: NSView {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            needsDisplay = true
        }
    }

    /// Which entry the picture belongs to. Changing it drops the zoom *without* telling
    /// the owner, because this is written from `updateNSView` — during a SwiftUI update,
    /// where writing state back would be the classic "modifying state during update". The
    /// SwiftUI side resets its own badge from the same record change.
    var recordID: UUID? {
        didSet {
            guard recordID != oldValue else { return }
            zoom.reset()
            reported = ReportedZoom(isZoomed: false, percent: 100)
            needsDisplay = true
        }
    }

    /// Told only when the *drawn* zoom changes, and only when the number the badge shows
    /// changes with it — a scroll gesture is dozens of events, and none of them should
    /// invalidate a SwiftUI tree to redraw the same two digits.
    var onZoomChange: ((Bool, CGFloat) -> Void)?

    private var zoom = ClipImageZoom()
    private var trackingArea: NSTrackingArea?
    private var dragging = false
    private var lastDragPoint: CGPoint?

    private struct ReportedZoom: Equatable {
        var isZoomed: Bool
        var percent: Int
    }
    private var reported = ReportedZoom(isZoomed: false, percent: 100)

    /// Read-only for tests; the view is the only thing that mutates it outside them.
    var zoomState: ClipImageZoom { zoom }

    override var isOpaque: Bool { false }
    /// The panel never takes key focus, so this view never needs to be a responder; it
    /// only wants the mouse events AppKit routes to whatever is under the pointer.
    override var acceptsFirstResponder: Bool { false }

    /// Every click into the floating preview is a first-mouse click. Double-click resets
    /// the zoom, which is the one gesture that has to survive that.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let rect = zoom.drawnRect(viewSize: bounds.size, imageSize: image.size)
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        // The picture is scaled up as often as down — a fit that has been zoomed, and a
        // 1024px decode on a 920px card — which is where the default interpolation shows.
        context.interpolationQuality = .high
        context.draw(cgImage, in: rect)
        context.restoreGState()
    }

    // MARK: - The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways`, because the panel is deliberately never the key window: an
        // area tied to key status would never fire at all. `.cursorUpdate` is what turns
        // the pointer into a hand over a zoomed picture, so that dragging it around is
        // something the user can see is possible.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Leaving the picture drops the zoom. Moving *within* it does nothing: the pointer
    /// has to cross the picture's edge, which the tracking area decides rather than a
    /// distance threshold that a shaky hand could trip.
    override func mouseExited(with event: NSEvent) {
        pointerDidExit()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        if dragging { NSCursor.closedHand.set() } else if zoom.isZoomed {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Zooming

    /// Half the sensitivity this shipped with.
    ///
    /// The first version multiplied the wheel's own delta straight into an exponential,
    /// and one notch of an ordinary wheel went from 100% to 221% — the whole range was
    /// crossed in three notches, which leaves nothing to aim with. Counting the *lines*
    /// rather than the pixels additionally separates the two devices: a mouse reports a
    /// few lines a notch, a trackpad a stream of points, and the same constant for both
    /// made one of them unusable.
    private static let lineStep: CGFloat = 0.05
    private static let preciseStep: CGFloat = 0.006

    /// The most one event may change the scale, whatever the device claims. A flick that
    /// arrives as one enormous delta should still move the zoom by a step a person can
    /// follow, not by a factor of three.
    private static let maxStep: CGFloat = 1.5

    /// The wheel and the trackpad's two-finger scroll.
    override func scrollWheel(with event: NSEvent) {
        let factor = Self.zoomFactor(
            scrollingDeltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas
        )
        guard factor != 1 else { return }
        applyZoom(factor: factor, at: convert(event.locationInWindow, from: nil))
    }

    /// The factor one scroll event is worth.
    ///
    /// Pulled out and made internal so the sensitivity can be pinned by a test. What it
    /// has to avoid is what the first version did: one notch of an ordinary wheel was
    /// worth `exp(0.10 × 8)`, a 121% jump, so three notches crossed the entire range and
    /// there was nothing left to aim with.
    static func zoomFactor(scrollingDeltaY: CGFloat, precise: Bool) -> CGFloat {
        let step = precise ? preciseStep : lineStep
        return bounded(exp(scrollingDeltaY * step))
    }

    /// The trackpad pinch.
    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        applyZoom(
            factor: Self.bounded(1 + event.magnification),
            at: convert(event.locationInWindow, from: nil)
        )
    }

    /// Keeps one event's factor inside `maxStep`, in either direction.
    private static func bounded(_ factor: CGFloat) -> CGFloat {
        guard factor.isFinite, factor > 0 else { return 1 }
        return min(max(factor, 1 / maxStep), maxStep)
    }

    // MARK: - Moving around

    /// Dragging pans the zoomed picture, so the detail away from where the pointer first
    /// landed is reached without zooming back out and hunting for it again. The scale is
    /// untouched — see `ClipImageZoom.pan`.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Two clicks back to fit, so a deep zoom can be undone without moving the pointer
        // off the picture and back.
        if event.clickCount >= 2 {
            endDrag()
            resetZoom()
            return
        }
        // Nothing to move when the whole picture is already visible.
        guard zoom.isZoomed else { return }
        dragging = true
        lastDragPoint = point
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let last = lastDragPoint, let image else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        let delta = CGSize(width: point.x - last.x, height: point.y - last.y)
        guard delta != .zero else { return }
        let before = zoom
        zoom.pan(by: delta, viewSize: bounds.size, imageSize: image.size)
        guard zoom != before else { return }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    private func endDrag() {
        dragging = false
        lastDragPoint = nil
        updateCursor()
    }

    /// The single entry point both zoom gestures use, and the one tests drive.
    func applyZoom(factor: CGFloat, at anchor: CGPoint) {
        guard let image else { return }
        let before = zoom
        zoom.zoom(by: factor, at: anchor, viewSize: bounds.size, imageSize: image.size)
        guard zoom != before else { return }
        reportZoom()
        updateCursor()
        needsDisplay = true
    }

    func resetZoom() {
        guard zoom.isZoomed else { return }
        zoom.reset()
        reportZoom()
        endDrag()
        needsDisplay = true
    }

    func pointerDidExit() {
        endDrag()
        resetZoom()
    }

    private func reportZoom() {
        // Keyed on the percentage the badge would *draw*, not on the raw scale: an
        // imperceptible nudge is not something to show a badge for, and the owner is the
        // one deciding whether to draw one.
        let percent = Int((zoom.scale * 100).rounded())
        let next = ReportedZoom(isZoomed: percent > 100, percent: percent)
        guard next != reported else { return }
        reported = next
        onZoomChange?(next.isZoomed, zoom.scale)
    }
}

/// The zoomable picture, bridged into the card.
struct ClipZoomableImage: NSViewRepresentable {
    let image: NSImage
    /// Changing this resets the zoom — see `ClipZoomableImageView.recordID`.
    let recordID: UUID
    let onZoomChange: (Bool, CGFloat) -> Void

    func makeNSView(context: Context) -> ClipZoomableImageView {
        let view = ClipZoomableImageView()
        view.onZoomChange = onZoomChange
        view.recordID = recordID
        view.image = image
        return view
    }

    func updateNSView(_ view: ClipZoomableImageView, context: Context) {
        view.onZoomChange = onZoomChange
        view.recordID = recordID
        view.image = image
    }
}
