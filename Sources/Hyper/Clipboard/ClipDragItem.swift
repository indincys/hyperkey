import AppKit
import Foundation
import UniformTypeIdentifiers
import os

/// Builds the `NSItemProvider` a row hands over when it is dragged out of the panel.
///
/// The governing constraint is that `.onDrag`'s closure runs on the main thread at the
/// instant the pointer starts moving. Reading a twenty-megabyte screenshot back off disk
/// there is a visible stall at exactly the wrong moment, so anything that could be large
/// is registered lazily: only the payload's *location* crosses into the load handler,
/// which the drag session calls off the main thread once a target actually asks for the
/// bytes. Entries that are small by their nature — a URL, a list of paths — are read
/// straight away, because their provider cannot be built without the value.
enum ClipDragItem {
    private static let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.drag")

    private enum Failure: Error { case unavailable }

    /// The type that says "this drag started in the panel".
    ///
    /// Registered on every row that leaves the list, alongside whatever the row actually
    /// carries, and read back by the panel's own drop targets: the 收藏 reorder has to know
    /// which row is in flight, and 拖入即存 has to *not* save a row that was dragged out and
    /// let go over the list again. Private and `.ownProcess`, so no other application ever
    /// sees it and a drag out is unchanged by it.
    static let privateTypeIdentifier = "com.indincys.hyper.cliprecord"

    /// Compatibility entry point used by SwiftUI's single-item `.onDrag` closure.
    /// `providers(representedBy:)` lets the AppKit bridge recover every sibling provider
    /// from this primary item and create a genuine multi-item `NSDraggingSession`.
    static func provider(for record: ClipRecord, store: ClipStore) -> NSItemProvider {
        let providers = providers(for: record, store: store)
        return primaryProvider(bundling: providers)
    }

    static func providers(for record: ClipRecord, store: ClipStore) -> [NSItemProvider] {
        // What the row already shows, for the cases where the payload is gone or was
        // never kept. Dragging out something recognisable beats dragging out nothing.
        let fallback = record.preview

        let content: [NSItemProvider]
        if record.oversized {
            content = [textProvider(fallback)]
        } else {
            switch record.kind {
            case .image:
                content = [imageProvider(recordID: record.id, store: store)]
            case .files:
                let urls = store.payloadData(for: record.id)
                    .flatMap(ClipPayloadCoder.decode)
                    .map(ClipCapture.fileURLs) ?? []
                content = urls.isEmpty
                    ? [textProvider(fallback)]
                    : fileProviders(for: urls, ownDragID: record.id)
            case .url:
                content = [urlProvider(recordID: record.id, store: store, fallback: fallback)]
            case .color:
                content = [textProvider(fallback)]
            case .text, .richText:
                content = [lazyTextProvider(recordID: record.id, store: store, fallback: fallback)]
            }
        }

        for provider in content {
            registerOwnDrag(record.id, on: provider)
        }
        return content
    }

    // MARK: - Per-kind providers

    /// Plain text, read only if someone asks for it.
    ///
    /// `plainTextOnly` rather than `plainText`: the styled-text fallback goes through
    /// `NSAttributedString`, which is main-thread-only, and this handler is not. A
    /// rich-text entry with no plain half therefore drags its preview line — the same
    /// compromise the preview pane makes.
    private static func lazyTextProvider(
        recordID: UUID, store: ClipStore, fallback: String
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all
        ) { completion in
            let text = payload(recordID: recordID, store: store)
                .flatMap(ClipCapture.plainTextOnly) ?? fallback
            completion(Data(text.utf8), nil)
            return nil
        }
        return provider
    }

    /// Text that is already in hand.
    private static func textProvider(_ text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(text as NSString, visibility: .all)
        return provider
    }

    /// A link drags as a link *and* as its own text, so it lands correctly in a browser
    /// tab bar and in a plain editor alike. Read eagerly: a URL entry is a few hundred
    /// bytes, and `NSURL` cannot be registered without the value.
    private static func urlProvider(
        recordID: UUID, store: ClipStore, fallback: String
    ) -> NSItemProvider {
        let text = (payload(recordID: recordID, store: store)
            .flatMap(ClipCapture.plainTextOnly) ?? fallback)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = NSItemProvider()
        if let url = URL(string: text), url.scheme != nil {
            provider.registerObject(url as NSURL, visibility: .all)
        }
        provider.registerObject(text as NSString, visibility: .all)
        return provider
    }

    /// Publishes every accepted image contract through the same bounded ImageIO path.
    /// If the requested type was captured, its exact bytes are returned (not a re-encode);
    /// otherwise ImageIO supplies a compatible conversion from the retained source.
    private static func imageProvider(recordID: UUID, store: ClipStore) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "剪贴板图片"
        for type in ClipImageCodec.typeIdentifiers {
            provider.registerDataRepresentation(
                forTypeIdentifier: type, visibility: .all
            ) { completion in
                guard let payload = payload(recordID: recordID, store: store),
                      let data = ClipImageCodec.representation(
                          from: payload, requestedType: type
                      )
                else {
                    log.error("image entry could not provide \(type, privacy: .public)")
                    completion(nil, Failure.unavailable)
                    return nil
                }
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    /// Exactly one provider per file or directory. A Finder destination sees these as
    /// independent dragging items, so item count and ordering survive both directions.
    static func fileProviders(for urls: [URL], ownDragID: UUID? = nil) -> [NSItemProvider] {
        urls.map { url in
            let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
            if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
                ) { completion in
                    completion(Data(url.absoluteString.utf8), nil)
                    return nil
                }
            }
            provider.suggestedName = url.lastPathComponent
            if let ownDragID { registerOwnDrag(ownDragID, on: provider) }
            remember(fileURL: url, for: provider)
            return provider
        }
    }

    // MARK: - Multi-item bridge

    private final class WeakPrimary {
        weak var value: NSItemProvider?
        let providers: [NSItemProvider]

        init(_ value: NSItemProvider, providers: [NSItemProvider]) {
            self.value = value
            self.providers = providers
        }
    }

    private static let bundleLock = NSLock()
    private static var bundles: [ObjectIdentifier: WeakPrimary] = [:]
    private static var fileURLsByProvider: [ObjectIdentifier: (WeakPrimary, URL)] = [:]

    private static func remember(
        _ providers: [NSItemProvider], representedBy primary: NSItemProvider
    ) {
        bundleLock.lock()
        bundles = bundles.filter { $0.value.value != nil }
        if bundles.count >= 128, let oldest = bundles.keys.first { bundles.removeValue(forKey: oldest) }
        bundles[ObjectIdentifier(primary)] = WeakPrimary(primary, providers: providers)
        bundleLock.unlock()
    }

    private static func remember(fileURL: URL, for provider: NSItemProvider) {
        bundleLock.lock()
        fileURLsByProvider = fileURLsByProvider.filter { $0.value.0.value != nil }
        if fileURLsByProvider.count >= 512, let oldest = fileURLsByProvider.keys.first {
            fileURLsByProvider.removeValue(forKey: oldest)
        }
        fileURLsByProvider[ObjectIdentifier(provider)] = (
            WeakPrimary(provider, providers: [provider]), fileURL
        )
        bundleLock.unlock()
    }

    static func primaryProvider(bundling providers: [NSItemProvider]) -> NSItemProvider {
        let primary = providers.first ?? NSItemProvider()
        remember(providers.isEmpty ? [primary] : providers, representedBy: primary)
        return primary
    }

    static func providers(representedBy primary: NSItemProvider) -> [NSItemProvider] {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        return bundles[ObjectIdentifier(primary)]?.providers ?? [primary]
    }

    static func releaseBundle(representedBy primary: NSItemProvider) {
        bundleLock.lock()
        let providers = bundles.removeValue(forKey: ObjectIdentifier(primary))?.providers ?? []
        for provider in providers {
            fileURLsByProvider.removeValue(forKey: ObjectIdentifier(provider))
        }
        bundleLock.unlock()
    }

    /// AppKit requires one `NSDraggingItem` per destination item. The frame is only the
    /// local lift preview; Finder receives the provider carried by each item unchanged.
    static func draggingItems(
        representedBy primary: NSItemProvider, at point: NSPoint
    ) -> [NSDraggingItem] {
        providers(representedBy: primary).enumerated().map { index, provider in
            let writer: NSPasteboardWriting
            bundleLock.lock()
            let fileURL = fileURLsByProvider[ObjectIdentifier(provider)]?.1
            bundleLock.unlock()
            if let fileURL {
                // `NSURL` is AppKit's canonical file drag writer. The parallel
                // `NSItemProvider` remains the lazy Transferable representation, while
                // Finder consumes one concrete writer from each dragging item.
                writer = fileURL as NSURL
            } else {
                // Reorder-only rows carry no public content. Their controller already
                // owns the record id for the in-process move; the marker is all the
                // destination needs to recognise the session as Hyper's own.
                let marker = NSPasteboardItem()
                marker.setData(Data(), forType: NSPasteboard.PasteboardType(privateTypeIdentifier))
                writer = marker
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 4)) * 3
            let frame = NSRect(
                x: point.x - 20 + offset, y: point.y - 20 - offset,
                width: 40, height: 40
            )
            let image = NSImage(
                systemSymbolName: provider.registeredTypeIdentifiers.contains(
                    where: { $0 == UTType.fileURL.identifier }
                ) ? "doc.fill" : "doc.on.clipboard",
                accessibilityDescription: nil
            )
            item.setDraggingFrame(frame, contents: image)
            return item
        }
    }

    private static func registerOwnDrag(_ id: UUID, on provider: NSItemProvider) {
        guard !provider.registeredTypeIdentifiers.contains(privateTypeIdentifier) else { return }
        provider.registerDataRepresentation(
            forTypeIdentifier: privateTypeIdentifier, visibility: .ownProcess
        ) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
    }

    // MARK: - Payload

    private static func payload(recordID: UUID, store: ClipStore) -> ClipPayload? {
        guard let data = store.payloadData(for: recordID) else { return nil }
        return ClipPayloadCoder.decode(data)
    }
}
