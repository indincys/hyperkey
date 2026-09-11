import AppKit

/// Where a panel of a given size goes on a given screen, for each `ClipPanelPosition`.
///
/// Broken out of `ClipboardPanelController` as arithmetic on plain values so the one
/// thing about placement that can be checked without a display — that the pointer modes
/// never park the panel under the cursor, and that every mode keeps it on screen — is a
/// test rather than an assumption. The controller supplies the pointer and the screen;
/// nothing here reads either for itself.
enum ClipPanelPlacement {
    /// The breathing room kept between the panel and the pointer in the modes that open
    /// beside or below it. Enough that the first row does not land under the cursor, which
    /// would hover that row on the opening frame.
    static let pointerGap: CGFloat = 14

    /// How far below the pointer the panel's top edge hangs in `.mouse`, so the pointer
    /// sits above the panel rather than on it.
    static let pointerDrop: CGFloat = 8

    /// Every placement ends in the same clamp, because the clamp is the actual promise:
    /// the panel's top-left corner is at least `screenMargin` inside the screen, and when
    /// the panel fits, so is its bottom-right. `.center`, in particular, used to nudge the
    /// panel up by 8% of the screen's height without checking the result — on a display
    /// only a little taller than the panel, that nudge hung the last rows off the bottom.
    static func origin(
        mode: ClipPanelPosition,
        size: NSSize,
        pointer: NSPoint,
        visible: NSRect,
        screenMargin: CGFloat,
        gap: CGFloat
    ) -> NSPoint {
        let raw: NSPoint
        switch mode {
        case .mouseRight:
            // Beside the pointer rather than under it, top edge level with it — where a
            // context menu opened from a click goes, and what the panel does by default.
            // With no room to the right it flips to the left rather than sliding under the
            // cursor, which is the one place it must not be.
            var x = pointer.x + gap
            if x + size.width > visible.maxX - screenMargin {
                x = pointer.x - gap - size.width
            }
            raw = NSPoint(x: x, y: pointer.y - size.height)
        case .center:
            // A little above centre, so the list sits where the eye already is rather
            // than at the very middle.
            raw = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2 + visible.height * 0.08
            )
        case .mouse:
            // The pointer marks the top edge, centred on it, and the panel hangs below.
            raw = NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - pointerDrop)
        case .bottom:
            raw = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        }
        return NSPoint(
            x: clamp(raw.x, low: visible.minX + screenMargin,
                     high: visible.maxX - size.width - screenMargin).rounded(),
            y: clamp(raw.y, low: visible.minY + screenMargin,
                     high: visible.maxY - size.height - screenMargin).rounded()
        )
    }

    /// Clamps to `low` when the range is empty — a screen narrower or shorter than the
    /// panel — so a cramped display still gets the panel's top-left corner on screen
    /// instead of a coordinate off the edge.
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
