import AppKit
import SwiftUI
import os

/// What the user did with the editor.
enum ClipEditorOutcome {
    /// The edited text, and whether it should be pasted straight afterwards.
    case saved(text: String, paste: Bool)
    case cancelled
}

/// Editable state, shared between the window and its SwiftUI content.
final class ClipEditorModel: ObservableObject {
    @Published var text = ""
    /// Remembered across openings rather than reset: someone who edits code once will
    /// edit code again, and re-flipping the switch every time is pure friction.
    @Published var monospaced = false

    var finish: (ClipEditorOutcome) -> Void = { _ in }

    var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A titled panel rather than the borderless kind the list uses: this one is a document
/// you sit in front of and type into, so it wants a title bar to drag and a close button,
/// and it very much does need to become key.
final class ClipEditorPanel: NSPanel {
    /// Key is all a text field needs; main stays off, which is the ordinary shape of a
    /// utility panel and keeps it out of the window-cycling order.
    override var canBecomeKey: Bool { true }
}

/// Opens the 「编辑…」 window and reports back exactly once.
///
/// The window is built lazily and then kept, so reopening it costs nothing and it comes
/// back where the user last dragged it.
final class ClipEditorController {
    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.editor")

    private var panel: ClipEditorPanel?
    private let model = ClipEditorModel()
    private var completion: ((ClipEditorOutcome) -> Void)?
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    private static let size = NSSize(width: 480, height: 320)

    /// Whether an edit is on screen. Every way out of a session orders the window out,
    /// so this answers "is someone in the middle of editing" as well.
    var isVisible: Bool { panel?.isVisible ?? false }

    init() {
        model.finish = { [weak self] outcome in self?.finish(outcome) }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    func show(text: String, completion: @escaping (ClipEditorOutcome) -> Void) {
        // An edit already in progress wins. Cancelling it to make room for this one
        // would throw away whatever has been typed, and the text on screen is the one
        // thing here the user cannot get back.
        guard self.completion == nil else {
            log.info("edit request ignored: a session is already open")
            bringToFront()
            return
        }

        self.completion = completion
        model.text = text

        let panel = existingPanel()
        // An accessory app has no Dock icon, so nothing brings this forward on its own —
        // and a window that never becomes key is a text editor you cannot type into.
        NSApp.activate(ignoringOtherApps: true)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// Puts an open editor back in front, for the paths that would otherwise open a
    /// second window over it — or open the list on top of an edit in progress.
    func bringToFront() {
        guard let panel, panel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func existingPanel() -> ClipEditorPanel {
        if let panel { return panel }

        let panel = ClipEditorPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "编辑内容"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ClipEditorView(model: model))

        // The red button is a cancel like any other; without this it would close the
        // window and leave the caller's completion hanging.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.finish(.cancelled) }

        self.panel = panel
        return panel
    }

    /// ⌘↩ and Escape, taken before the text view sees them.
    ///
    /// SwiftUI's `.keyboardShortcut(.cancelAction)` is not enough here: a focused
    /// `TextEditor` handles Escape itself, so the button never hears about it.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            let command = event.modifierFlags.contains(.command)
            if event.keyCode == 53 {  // escape
                self.finish(.cancelled)
                return nil
            }
            // Return alone belongs to the text view — this is a multi-line editor.
            guard command, event.keyCode == 36 || event.keyCode == 76, self.model.canSave
            else { return event }
            self.finish(.saved(text: self.model.text, paste: true))
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Reports the outcome once and only once — every path out of the window funnels
    /// through here, including the ones that arrive twice (a button, then the
    /// `willClose` that ordering the window out provokes).
    ///
    /// The teardown runs on every arrival and only the callback is guarded: a window
    /// closed with no session behind it would otherwise leave the key monitor installed,
    /// swallowing Escape and ⌘↩ for as long as the editor stayed key.
    private func finish(_ outcome: ClipEditorOutcome) {
        removeKeyMonitor()
        panel?.orderOut(nil)
        guard let completion else { return }
        self.completion = nil
        completion(outcome)
    }
}

private struct ClipEditorView: View {
    @ObservedObject var model: ClipEditorModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.text)
                .font(.system(size: 12.5, design: model.monospaced ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.6)

            HStack(spacing: 8) {
                Toggle(isOn: $model.monospaced) {
                    Image(systemName: "textformat.alt").font(.system(size: 11))
                }
                .toggleStyle(.button)
                .help("等宽字体")

                Text("⌘↩ 保存并粘贴 · Esc 取消")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Button("取消") { model.finish(.cancelled) }
                Button("仅保存") { model.finish(.saved(text: model.text, paste: false)) }
                    .disabled(!model.canSave)
                Button("保存并粘贴") { model.finish(.saved(text: model.text, paste: true)) }
                    .disabled(!model.canSave)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(minWidth: 380, minHeight: 240)
    }
}
