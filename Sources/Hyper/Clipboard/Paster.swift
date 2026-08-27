import AppKit
import Foundation
import os

/// Puts content on the pasteboard and makes the frontmost application paste it.
///
/// Every fallible boundary reports a value. In particular, callers must not infer that
/// an event was delivered merely because this method returned: queue consumption is
/// committed only after `sendPaste` reports that both key events were constructed and
/// handed to Core Graphics.
enum Paster {
    private static let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.paste")

    struct Placement: Equatable {
        let changeCount: Int
    }

    enum PlacementFailure: Error, Equatable {
        case emptyPayload
        case plainTextUnavailable
        case incompatiblePayload(index: Int)
        case pasteboardRejected
    }

    struct PasteboardSnapshot: Equatable {
        let payload: ClipPayload
        let changeCount: Int
    }

    enum RestoreResult: Equatable {
        case restored(changeCount: Int)
        case skippedPasteboardChanged(expected: Int, actual: Int)
        case failed(PlacementFailure)
    }

    enum ActivationResult: Equatable {
        case ready
        case targetUnavailable
    }

    enum EventFailure: Error, Equatable {
        case eventSourceUnavailable
        case eventConstructionFailed(keyDown: Bool)
        case eventPostingFailed(keyDown: Bool)
        case queueCommit(PasteQueue.DequeueCommitFailure)
    }

    struct EventDelivery: Equatable {
        let eventCount: Int
    }

    /// The smallest possible Core Graphics seam. Production still constructs genuine
    /// `CGEventSource`/`CGEvent` values; tests can fail either construction or delivery
    /// without posting a real command-V into whichever application owns the test run.
    struct EventEnvironment {
        var makeSource: () -> CGEventSource?
        var makeEvent: (CGEventSource, CGKeyCode, Bool) -> CGEvent?
        var post: (CGEvent) -> Bool

        static let live = EventEnvironment(
            makeSource: { CGEventSource(stateID: .hidSystemState) },
            makeEvent: { source, key, down in
                CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            },
            post: { event in
                event.post(tap: .cghidEventTap)
                // Core Graphics has no acknowledgement API. This means only that the
                // event was successfully constructed and handed to `post`, which is the
                // honest, observable commit boundary available on macOS.
                return true
            }
        )
    }

    // MARK: - Pasteboard writes

    static func place(
        _ payload: ClipPayload,
        plainTextOnly: Bool,
        to pasteboard: NSPasteboard = .general
    ) -> Result<Placement, PlacementFailure> {
        if plainTextOnly {
            guard let text = ClipCapture.plainText(from: payload) else {
                return .failure(.plainTextUnavailable)
            }
            return placeText(text, to: pasteboard)
        }

        guard !payload.isEmpty else { return .failure(.emptyPayload) }
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(payload.count)
        for bucket in payload {
            guard !bucket.isEmpty else { return .failure(.emptyPayload) }
            let item = NSPasteboardItem()
            for (type, data) in bucket {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else {
                    return .failure(.pasteboardRejected)
                }
            }
            items.append(item)
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return .failure(.pasteboardRejected) }
        return .success(Placement(changeCount: pasteboard.changeCount))
    }

    /// Writes several entries as one, joined by `separator`. Every input must be
    /// representable as text (file entries contribute their paths); otherwise the whole
    /// operation is rejected before the pasteboard is touched.
    static func placeMerged(
        _ payloads: [ClipPayload],
        separator: String,
        to pasteboard: NSPasteboard = .general
    ) -> Result<Placement, PlacementFailure> {
        switch flatten(payloads, separator: separator) {
        case .success(let text): return placeText(text, to: pasteboard)
        case .failure(let failure): return .failure(failure)
        }
    }

    static func placeTransformed(
        _ payloads: [ClipPayload],
        separator: String,
        transform: PasteTransform,
        to pasteboard: NSPasteboard = .general
    ) -> Result<Placement, PlacementFailure> {
        switch flatten(payloads, separator: separator) {
        case .success(let text): return placeText(transform.apply(to: text), to: pasteboard)
        case .failure(let failure): return .failure(failure)
        }
    }

    static func placeText(
        _ text: String, to pasteboard: NSPasteboard = .general
    ) -> Result<Placement, PlacementFailure> {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .failure(.pasteboardRejected)
        }
        return .success(Placement(changeCount: pasteboard.changeCount))
    }

    private static func flatten(
        _ payloads: [ClipPayload], separator: String
    ) -> Result<String, PlacementFailure> {
        guard !payloads.isEmpty else { return .failure(.emptyPayload) }
        var pieces: [String] = []
        pieces.reserveCapacity(payloads.count)
        for (index, payload) in payloads.enumerated() {
            if let text = ClipCapture.plainText(from: payload) {
                pieces.append(text)
                continue
            }
            let urls = ClipCapture.fileURLs(from: payload)
            guard !urls.isEmpty else { return .failure(.incompatiblePayload(index: index)) }
            pieces.append(urls.map(\.path).joined(separator: separator))
        }
        return .success(pieces.joined(separator: separator))
    }

    static func isMergeCompatible(_ payload: ClipPayload) -> Bool {
        if ClipCapture.plainText(from: payload) != nil { return true }
        return !ClipCapture.fileURLs(from: payload).isEmpty
    }

    static func snapshot(_ pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        var payload: ClipPayload = []
        for item in pasteboard.pasteboardItems ?? [] {
            var bucket: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                bucket[type.rawValue] = data
            }
            if !bucket.isEmpty { payload.append(bucket) }
        }
        return PasteboardSnapshot(payload: payload, changeCount: pasteboard.changeCount)
    }

    /// Restores only if nobody has touched the pasteboard since our paste landed. The
    /// compare happens on the same main-thread turn as the write; this is the closest
    /// public NSPasteboard offers to compare-and-swap.
    static func restore(
        _ snapshot: PasteboardSnapshot,
        ifUnchangedSince expectedChangeCount: Int,
        to pasteboard: NSPasteboard = .general
    ) -> RestoreResult {
        let actual = pasteboard.changeCount
        guard actual == expectedChangeCount else {
            return .skippedPasteboardChanged(expected: expectedChangeCount, actual: actual)
        }
        if snapshot.payload.isEmpty {
            pasteboard.clearContents()
            return .restored(changeCount: pasteboard.changeCount)
        }
        switch place(snapshot.payload, plainTextOnly: false, to: pasteboard) {
        case .success(let placement): return .restored(changeCount: placement.changeCount)
        case .failure(let failure): return .failed(failure)
        }
    }

    static let minimumRestoreDelay: TimeInterval = 0.2
    static let maximumRestoreDelay: TimeInterval = 1.5

    /// Gives the receiving application a bounded opportunity to consume the payload.
    /// More items, representations and bytes cost more, as does switching applications;
    /// the hard ceiling keeps a lost callback or pathological payload from turning this
    /// into an unbounded clipboard ownership window. The later CAS remains the final
    /// authority if the user copies something during that window.
    static func restoreDelay(
        for payloads: [ClipPayload], targetActivationRequired: Bool
    ) -> TimeInterval {
        let byteCostCeiling = 16 * 1024 * 1024
        var byteCount = 0
        var itemCount = 0
        var representationCount = 0
        var hasExpensiveRepresentation = false
        let expensiveTypes: Set<String> = [
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.html.rawValue,
            NSPasteboard.PasteboardType.fileURL.rawValue,
        ]

        for payload in payloads {
            itemCount += payload.count
            for bucket in payload {
                representationCount += bucket.count
                if !hasExpensiveRepresentation,
                   bucket.keys.contains(where: expensiveTypes.contains) {
                    hasExpensiveRepresentation = true
                }
                for data in bucket.values where byteCount < byteCostCeiling {
                    byteCount += min(data.count, byteCostCeiling - byteCount)
                }
            }
        }

        let activationCost: TimeInterval = targetActivationRequired ? 0.25 : 0
        let byteCost = min(0.7, 0.7 * Double(byteCount) / Double(byteCostCeiling))
        let itemCost = min(0.25, Double(itemCount) * 0.012)
        let representationCost = min(0.12, Double(representationCount) * 0.004)
        let decodingCost: TimeInterval = hasExpensiveRepresentation ? 0.15 : 0
        let computed = minimumRestoreDelay + activationCost + byteCost
            + itemCost + representationCost + decodingCost
        return min(maximumRestoreDelay, max(minimumRestoreDelay, computed))
    }

    // MARK: - Target activation

    static func withApplicationFrontmost(
        _ app: NSRunningApplication?, then body: @escaping (ActivationResult) -> Void
    ) {
        guard let app else {
            body(.ready)
            return
        }
        guard !app.isTerminated, app.activate(options: []) else {
            body(.targetUnavailable)
            return
        }

        let alreadyFrontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        if alreadyFrontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { body(.ready) }
            return
        }

        var attempts = 0
        func waitForFront() {
            guard !app.isTerminated else {
                body(.targetUnavailable)
                return
            }
            attempts += 1
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { body(.ready) }
                return
            }
            guard attempts <= 25 else {
                log.warning("target app never came to the front; paste cancelled")
                body(.targetUnavailable)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { waitForFront() }
        }
        waitForFront()
    }

    // MARK: - Synthetic keystrokes

    private static let vKey: CGKeyCode = 9
    private static let cKey: CGKeyCode = 8
    private static let nonCoalesced = CGEventFlags(rawValue: 0x100)

    static func sendPaste(
        using environment: EventEnvironment = .live
    ) -> Result<EventDelivery, EventFailure> {
        send(key: vKey, using: environment)
    }

    static func sendCopy(
        using environment: EventEnvironment = .live
    ) -> Result<EventDelivery, EventFailure> {
        send(key: cKey, using: environment)
    }

    private static func send(
        key: CGKeyCode, using environment: EventEnvironment
    ) -> Result<EventDelivery, EventFailure> {
        guard let source = environment.makeSource() else {
            log.error("could not create an event source for the synthetic keystroke")
            return .failure(.eventSourceUnavailable)
        }
        let flags: CGEventFlags = [.maskCommand, nonCoalesced]
        var events: [(event: CGEvent, keyDown: Bool)] = []
        for down in [true, false] {
            guard let event = environment.makeEvent(source, key, down) else {
                return .failure(.eventConstructionFailed(keyDown: down))
            }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Hyper.syntheticEventMarker)
            events.append((event, down))
        }

        var failedDirection: Bool?
        for pair in events where !environment.post(pair.event) {
            failedDirection = failedDirection ?? pair.keyDown
        }
        if let failedDirection { return .failure(.eventPostingFailed(keyDown: failedDirection)) }
        return .success(EventDelivery(eventCount: events.count))
    }
}
