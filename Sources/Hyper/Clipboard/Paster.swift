import AppKit
import Foundation
import os

/// Puts content on the pasteboard and makes the frontmost application paste it.
///
/// Three things have to line up, and getting any of them wrong produces a paste that
/// silently does nothing:
///
///   1. **The target application must be frontmost again.** The panel is a
///      non-activating panel so focus usually never leaves, but a paste triggered from
///      the panel still re-activates the remembered application defensively.
///   2. **No modifiers may be latched.** Every one of these actions is reached through
///      a hyper binding, which means ⌘⌃⌥⇧ are held down at the moment the key fires.
///      A ⌘V synthesized then arrives as ⌘⌃⌥⇧V and pastes nothing. The caller must
///      therefore defer the paste until the hyper key is released — see
///      `HyperTap.runAfterHyperRelease`.
///   3. **The synthetic keystroke must be tagged.** Otherwise our own event tap
///      processes it and merges the hyper mask straight back in.
enum Paster {
    private static let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.paste")

    /// Writes a payload to the pasteboard.
    /// Returns the change count the write landed on, so the monitor can ignore it.
    /// The pasteboard is injectable so tests can run without disturbing the real one.
    @discardableResult
    static func place(
        _ payload: ClipPayload,
        plainTextOnly: Bool,
        to pasteboard: NSPasteboard = .general
    ) -> Int {
        let changeCount = pasteboard.clearContents()

        if plainTextOnly {
            let text = ClipCapture.plainText(from: payload) ?? ""
            pasteboard.setString(text, forType: .string)
            return changeCount
        }

        var items: [NSPasteboardItem] = []
        for bucket in payload {
            let item = NSPasteboardItem()
            for (type, data) in bucket {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            items.append(item)
        }
        guard !items.isEmpty else { return changeCount }
        pasteboard.writeObjects(items)
        return changeCount
    }

    /// Writes several entries as one, joined by `separator`.
    ///
    /// Merging only makes sense for text, so this flattens everything to plain text —
    /// including file entries, which contribute their paths.
    @discardableResult
    static func placeMerged(
        _ payloads: [ClipPayload],
        separator: String,
        to pasteboard: NSPasteboard = .general
    ) -> Int {
        let pieces: [String] = payloads.compactMap { payload in
            if let text = ClipCapture.plainText(from: payload), !text.isEmpty { return text }
            let urls = ClipCapture.fileURLs(from: payload)
            if !urls.isEmpty { return urls.map(\.path).joined(separator: separator) }
            return nil
        }
        let changeCount = pasteboard.clearContents()
        pasteboard.setString(pieces.joined(separator: separator), forType: .string)
        return changeCount
    }

    /// Snapshot of the pasteboard, so it can be put back after a paste.
    static func snapshot(_ pasteboard: NSPasteboard = .general) -> ClipPayload? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var payload: ClipPayload = []
        for item in items {
            var bucket: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                bucket[type.rawValue] = data
            }
            if !bucket.isEmpty { payload.append(bucket) }
        }
        return payload.isEmpty ? nil : payload
    }

    // MARK: - Synthetic keystrokes

    private static let vKey: CGKeyCode = 9
    private static let cKey: CGKeyCode = 8
    /// Real keyboard events carry this bit; synthesized ones should too, or some
    /// applications treat them as coalesced repeats and drop them.
    private static let nonCoalesced = CGEventFlags(rawValue: 0x100)

    /// Brings `app` back to the front if it is not already there, then runs `body`.
    /// Activation is asynchronous, so `body` is deferred until it has actually taken
    /// effect rather than after a fixed guess.
    static func withApplicationFrontmost(
        _ app: NSRunningApplication?, then body: @escaping () -> Void
    ) {
        guard let app, !app.isTerminated else {
            body()
            return
        }

        let alreadyFrontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier

        // Activated even when it is already frontmost. The panel is a non-activating
        // panel, so it takes the keyboard focus without ever displacing the frontmost
        // application — which means "already frontmost" is not the same as "will
        // receive the keystroke", and this is the call that makes it so.
        app.activate(options: [])

        if alreadyFrontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: body)
            return
        }

        // Poll briefly for the activation to land. Capped, so a refusal to activate
        // costs a short delay instead of dropping the paste entirely.
        var attempts = 0
        func waitForFront() {
            attempts += 1
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                || attempts > 25 {
                if attempts > 25 { log.warning("target app never came to the front; pasting anyway") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: body)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { waitForFront() }
        }
        waitForFront()
    }

    static func sendPaste() { send(key: vKey) }

    static func sendCopy() { send(key: cKey) }

    private static func send(key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log.error("could not create an event source for the synthetic keystroke")
            return
        }
        // Anything the user is still physically holding would be merged into the flags
        // of a real event. We set the flags explicitly to exactly ⌘ so a leftover
        // Shift or Option cannot turn ⌘V into ⇧⌘V.
        let flags: CGEventFlags = [.maskCommand, nonCoalesced]
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Hyper.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
