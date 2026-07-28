import Cocoa
import SwiftUI

/// A "press the key you want" field.
///
/// Drawn in AppKit rather than SwiftUI because it has to own first-responder status to
/// receive raw key events, and it must see keys the responder chain would otherwise
/// eat — Tab moves focus, Space clicks buttons, letters may match menu shortcuts.
final class KeyRecorderView: NSView {
    var keyName: String = "a" { didSet { needsDisplay = true } }
    var isDuplicate = false { didSet { needsDisplay = true } }
    var onCapture: ((String) -> Void)?

    private(set) var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Recording

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        window?.makeFirstResponder(self)
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { endRecording() } else { beginRecording() }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let code = CGKeyCode(event.keyCode)
        // Escape backs out without changing anything — the standard shortcut-recorder
        // convention, and the only way to leave the field alone once it is armed.
        if code == Keys.escape {
            endRecording()
            return
        }
        onCapture?(Keys.name(for: code))
        endRecording()
    }

    /// Claims keys that the responder chain would otherwise route to a menu or button.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    /// Modifiers alone are never a binding — the hyper key already supplies those.
    override func flagsChanged(with event: NSEvent) {}

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)

        let fill: NSColor
        let stroke: NSColor
        if isRecording {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.15)
            stroke = .controlAccentColor
        } else if isDuplicate {
            fill = NSColor.systemOrange.withAlphaComponent(0.12)
            stroke = .systemOrange
        } else {
            fill = .controlBackgroundColor
            stroke = .separatorColor
        }
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = isRecording || isDuplicate ? 2 : 1
        path.stroke()

        let text = isRecording ? "按下按键…" : Keys.display(forName: keyName)
        let color: NSColor = isRecording ? .controlAccentColor : .labelColor
        let size: CGFloat = isRecording ? 11 : 13
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: isRecording ? .regular : .medium),
            .foregroundColor: color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        attributed.draw(at: NSPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        ))
    }
}

// MARK: - SwiftUI bridge

struct KeyRecorderField: NSViewRepresentable {
    let keyName: String
    let isDuplicate: Bool
    let onCapture: (String) -> Void

    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView(frame: .zero)
        view.keyName = keyName
        view.isDuplicate = isDuplicate
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: KeyRecorderView, context: Context) {
        // Never overwrite what is on screen mid-capture: the model still holds the old
        // key at that point, and writing it back would fight the user's input.
        guard !view.isRecording else { return }
        view.keyName = keyName
        view.isDuplicate = isDuplicate
        view.onCapture = onCapture
    }
}
