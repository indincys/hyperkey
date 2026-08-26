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

    static func provider(for record: ClipRecord, store: ClipStore) -> NSItemProvider {
        let provider = content(for: record, store: store)
        provider.registerDataRepresentation(
            forTypeIdentifier: privateTypeIdentifier, visibility: .ownProcess
        ) { completion in
            completion(Data(record.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    private static func content(for record: ClipRecord, store: ClipStore) -> NSItemProvider {
        let location = store.payloadLocation(for: record.id)
        // What the row already shows, for the cases where the payload is gone or was
        // never kept. Dragging out something recognisable beats dragging out nothing.
        let fallback = record.preview

        guard !record.oversized else { return textProvider(fallback) }

        switch record.kind {
        case .image:
            return imageProvider(at: location)
        case .files:
            return fileProvider(at: location, fallback: fallback)
        case .url:
            return urlProvider(at: location, fallback: fallback)
        case .color:
            // Nothing to read back: `makePreview` already put the parsed `#RRGGBB` in
            // the preview line, and the notation is the whole of what a colour drags as.
            return textProvider(fallback)
        case .text, .richText:
            return lazyTextProvider(at: location, fallback: fallback)
        }
    }

    // MARK: - Per-kind providers

    /// Plain text, read only if someone asks for it.
    ///
    /// `plainTextOnly` rather than `plainText`: the styled-text fallback goes through
    /// `NSAttributedString`, which is main-thread-only, and this handler is not. A
    /// rich-text entry with no plain half therefore drags its preview line — the same
    /// compromise the preview pane makes.
    private static func lazyTextProvider(at location: URL, fallback: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all
        ) { completion in
            let text = payload(at: location).flatMap(ClipCapture.plainTextOnly) ?? fallback
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
    private static func urlProvider(at location: URL, fallback: String) -> NSItemProvider {
        let text = (payload(at: location).flatMap(ClipCapture.plainTextOnly) ?? fallback)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = NSItemProvider()
        if let url = URL(string: text), url.scheme != nil {
            provider.registerObject(url as NSURL, visibility: .all)
        }
        provider.registerObject(text as NSString, visibility: .all)
        return provider
    }

    /// Always PNG, never TIFF.
    ///
    /// `ClipCapture.read` already drops the TIFF half of a screenshot when a PNG of the
    /// same picture is present, so registering a single type keeps the provider honest —
    /// a target that asks for the one type we advertise always gets bytes. The rare
    /// TIFF-only entry is transcoded in the handler, through `NSBitmapImageRep`'s codec
    /// rather than through `NSImage`'s drawing, which would need the main thread.
    private static func imageProvider(at location: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "剪贴板图片.png"
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier, visibility: .all
        ) { completion in
            guard let payload = payload(at: location) else {
                completion(nil, Failure.unavailable)
                return nil
            }
            for item in payload {
                if let data = item[NSPasteboard.PasteboardType.png.rawValue] {
                    completion(data, nil)
                    return nil
                }
            }
            for item in payload {
                guard let tiff = item[NSPasteboard.PasteboardType.tiff.rawValue],
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { continue }
                completion(png, nil)
                return nil
            }
            log.error("image entry had neither PNG nor convertible TIFF to drag")
            completion(nil, Failure.unavailable)
            return nil
        }
        return provider
    }

    /// `.onDrag` yields one item and one item only, so a multi-file entry drags its first
    /// file and offers the whole list as text beside it — dropping four paths into an
    /// editor still works, dropping four files into Finder does not. Lifting that would
    /// mean driving `NSDraggingSession` from a custom view, which is a much larger change
    /// than the case is worth.
    private static func fileProvider(at location: URL, fallback: String) -> NSItemProvider {
        let urls = payload(at: location).map(ClipCapture.fileURLs) ?? []
        guard let first = urls.first else { return textProvider(fallback) }

        let provider = NSItemProvider(contentsOf: first) ?? NSItemProvider()
        provider.registerObject(
            urls.map(\.path).joined(separator: "\n") as NSString, visibility: .all
        )
        return provider
    }

    // MARK: - Payload

    private static func payload(at location: URL) -> ClipPayload? {
        guard let data = try? Data(contentsOf: location) else { return nil }
        return ClipPayloadCoder.decode(data)
    }
}
