import AppKit

/// A small transient message near the bottom of the screen.
///
/// Batch collecting has no visible result on its own — the content goes into a queue
/// the user cannot see — so without this, `Hyper + Q` would feel like it did nothing.
/// The HUD is what turns "did that work?" into "3 queued".
final class ClipboardHUD {
    static let shared = ClipboardHUD()

    /// What kind of news this is, carried by the icon's colour alone.
    ///
    /// Colour and nothing else: the HUD is read in half a second out of the corner of an
    /// eye, and a second line of "错误：" would be spending the one glance it gets on
    /// saying what the wording already says.
    enum Style {
        case normal
        case success
        case warning

        var tint: NSColor {
            switch self {
            case .normal: return .secondaryLabelColor
            case .success: return .systemGreen
            case .warning: return .systemOrange
            }
        }
    }

    /// How much of a content summary the second line carries. Long enough to recognise
    /// what was acted on, short enough that the HUD stays a HUD.
    private static let detailLimit = 30

    private var panel: NSPanel?
    private var label: NSTextField?
    private var detailLabel: NSTextField?
    private var symbolView: NSImageView?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    /// `detail` is a summary of *what* was acted on — the entry's own text, usually.
    /// Passed raw: collapsing and truncating it happens here so no call site has to
    /// remember to, and so every HUD in the app cuts at the same place.
    func show(
        _ text: String,
        detail: String? = nil,
        symbol: String = "doc.on.clipboard",
        style: Style = .normal,
        duration: TimeInterval = 1.3
    ) {
        let panel = existingPanel()
        label?.stringValue = text
        let summary = detail.flatMap(Self.summarise)
        detailLabel?.stringValue = summary ?? ""
        // Hidden rather than emptied: an empty label in a stack still claims its line
        // height, and the HUD would sit visibly off-centre with nothing in it.
        detailLabel?.isHidden = summary == nil
        symbolView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolView?.contentTintColor = style.tint

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

    /// One line, no runs of blanks, and never longer than `detailLimit`. A copied code
    /// block is mostly indentation, and dropped into the HUD unchanged it would show as
    /// thirty characters of nothing.
    private static func summarise(_ detail: String) -> String? {
        let collapsed = detail
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > detailLimit else { return collapsed }
        return String(collapsed.prefix(detailLimit)) + "…"
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

        let detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [label, detailLabel])
        text.orientation = .vertical
        text.spacing = 1
        text.alignment = .leading
        text.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [symbolView, text])
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
            // Thirty CJK characters would otherwise make the HUD wider than the window
            // it is reporting on. Past this the line truncates instead.
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])

        panel.contentView = effect
        self.panel = panel
        self.label = label
        self.detailLabel = detailLabel
        self.symbolView = symbolView
        return panel
    }

    private func layout(_ panel: NSPanel) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? .zero
        // Height follows the content now that there can be a second line, with the
        // one-line HUD's 44pt as the floor so the common case is unchanged.
        let size = NSSize(
            width: max(160, fitting.width + 8),
            height: max(44, fitting.height + 20)
        )

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
