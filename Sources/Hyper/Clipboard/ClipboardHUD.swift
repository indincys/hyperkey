import AppKit

/// A small transient message near the bottom of the screen.
///
/// Batch collecting has no visible result on its own — the content goes into a queue
/// the user cannot see — so without this, `Hyper + Q` would feel like it did nothing.
/// The HUD is what turns "did that work?" into "3 queued".
final class ClipboardHUD {
    static let shared = ClipboardHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var symbolView: NSImageView?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ text: String, symbol: String = "doc.on.clipboard", duration: TimeInterval = 1.3) {
        let panel = existingPanel()
        label?.stringValue = text
        symbolView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)

        layout(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Construction

    private func existingPanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let symbolView = NSImageView()
        symbolView.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [symbolView, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
        ])

        panel.contentView = effect
        self.panel = panel
        self.label = label
        self.symbolView = symbolView
        return panel
    }

    private func layout(_ panel: NSPanel) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? .zero
        let size = NSSize(width: max(160, fitting.width + 8), height: 44)

        // Follow the screen the pointer is on, which is the one the user is working on.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + 96,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }
}
