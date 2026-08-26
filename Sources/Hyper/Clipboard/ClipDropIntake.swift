import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

/// Turns something dropped onto the panel into one history entry.
///
/// The counterpart to `ClipDragItem`, and deliberately its mirror image: what comes back
/// is a `ClipPayload` and a `ClipKind`, which is exactly what the capture path hands
/// `ClipStore.insert`. Everything downstream of that — the preview line, the thumbnail,
/// the search text, the size cap — is then the same code a copy goes through, so a
/// dragged-in picture is indistinguishable from a copied one the moment it is in the list.
///
/// `NSItemProvider` loads asynchronously and calls back on a queue of its own choosing,
/// so every path here hops to the main thread before the completion runs: the store is
/// main-thread-only state.
enum ClipDropIntake {
    private static let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.drop")

    /// What the list will take a drop of.
    ///
    /// Which of them a given drop is *read* as is decided in `read(_:completion:)`, not
    /// here — a Finder drag carries a file URL, a name and a preview picture all at once,
    /// and the file URL is the one that says what the thing is.
    static let acceptedTypes: [UTType] = [
        .fileURL, .png, .tiff, .url, .utf8PlainText, .plainText,
    ]

    /// The name a dropped entry wears where a captured one names the application it was
    /// copied from. There is no such application here: the drop says where the content
    /// landed, never where it came from.
    static let sourceName = "拖入"

    /// Whether what is in flight is a row that left this panel a moment ago.
    static func isOwnDrag(_ info: DropInfo) -> Bool {
        info.itemProviders(for: acceptedTypes).contains {
            $0.registeredTypeIdentifiers.contains(ClipDragItem.privateTypeIdentifier)
        }
    }

    /// What a read produced: a payload and its kind, or `nil` for both when the drop held
    /// nothing this can store.
    ///
    /// Both halves go `nil` together — they are one answer in two pieces, kept as two
    /// arguments because that is what every caller wants to receive.
    typealias Completion = (ClipPayload?, ClipKind?) -> Void

    /// Reads the providers and calls back on the main thread, exactly once, with one
    /// entry's worth of content — or with `nil` when there was nothing readable in them.
    ///
    /// Nothing readable is not an error in itself, but it may not pass in silence either:
    /// the list has been wearing a blue border promising that letting go files the content
    /// away, and `performDrop` has already returned `true` to say it did. A promised file
    /// that Safari or Mail never delivers takes exactly this path, and the user is owed
    /// the news that the drop came to nothing.
    static func read(_ providers: [NSItemProvider], completion: @escaping Completion) {
        let files = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if !files.isEmpty {
            readFiles(files, completion: completion)
            return
        }
        let imageTypes = [UTType.png.identifier, UTType.tiff.identifier]
        if let image = providers.first(where: { provider in
            imageTypes.contains(where: provider.hasItemConformingToTypeIdentifier)
        }) {
            readImage(image, completion: completion)
            return
        }
        guard let first = providers.first else {
            fail(completion)
            return
        }
        readText(first, completion: completion)
    }

    /// The one way a read reports having found nothing, so no early return can forget to
    /// report at all. Hops to the main thread like every success does, and asynchronously
    /// even when it is already there: a completion that sometimes runs before `read`
    /// returns and sometimes long after is the kind of difference callers get wrong.
    private static func fail(_ completion: @escaping Completion) {
        DispatchQueue.main.async { completion(nil, nil) }
    }

    // MARK: - Per-kind reads

    /// Every file in the drop, as one entry — dragging four files in should produce the
    /// row that dragging four files *out* would produce, not four rows.
    private static func readFiles(
        _ providers: [NSItemProvider], completion: @escaping Completion
    ) {
        let group = DispatchGroup()
        // Written into a slot each rather than appended: the loads finish in whatever
        // order they finish in, and the entry should keep the order they were dragged in.
        var urls = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { data, error in
                defer { group.leave() }
                guard let data, let string = text(from: data), let url = URL(string: string)
                else {
                    log.error("dropped file URL could not be read: \(error?.localizedDescription ?? "no data", privacy: .public)")
                    return
                }
                lock.lock()
                urls[index] = url
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let resolved = urls.compactMap { $0 }
            // Every load failed — a promise the source application did not keep. Already
            // on the main thread here, but reported through the same door as every other
            // failure so there is one place to change what "nothing came of it" does.
            guard !resolved.isEmpty else {
                fail(completion)
                return
            }
            // One pasteboard item per file, keyed exactly as a Finder copy writes it —
            // `ClipCapture.fileURLs` reads the absolute string back out of this.
            let payload: ClipPayload = resolved.map {
                ["public.file-url": Data($0.absoluteString.utf8)]
            }
            completion(payload, .files)
        }
    }

    private static func readImage(
        _ provider: NSItemProvider, completion: @escaping Completion
    ) {
        // PNG where there is one, TIFF only where there is not — the same choice
        // `ClipCapture.read` makes on the way in, and for the same reason: the TIFF half
        // of a screenshot is routinely ten times the size of the PNG of the same picture.
        let type = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
            ? UTType.png.identifier
            : UTType.tiff.identifier

        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
            guard let data, !data.isEmpty else {
                log.error("dropped image could not be read: \(error?.localizedDescription ?? "no data", privacy: .public)")
                fail(completion)
                return
            }
            DispatchQueue.main.async { completion([[type: data]], .image) }
        }
    }

    /// A link or a piece of text, stored as characters either way.
    ///
    /// A dropped URL becomes a plain-text payload rather than keeping `public.url`,
    /// because that is what an edited entry's payload already looks like and what every
    /// reader here looks for first — and `textKind` puts it on the 链接 tab regardless.
    private static func readText(
        _ provider: NSItemProvider, completion: @escaping Completion
    ) {
        let candidates = [
            UTType.utf8PlainText.identifier, UTType.url.identifier, UTType.plainText.identifier,
        ]
        guard let type = candidates.first(where: provider.hasItemConformingToTypeIdentifier)
        else {
            fail(completion)
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
            guard let data, let string = text(from: data) else {
                log.error("dropped text could not be read: \(error?.localizedDescription ?? "no data", privacy: .public)")
                fail(completion)
                return
            }
            // Whitespace only. Storing it would put a blank row in the history, so this
            // counts as nothing to save rather than as something saved.
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail(completion)
                return
            }
            DispatchQueue.main.async {
                // One key covers it: `NSPasteboard.PasteboardType.string` *is*
                // "public.utf8-plain-text".
                completion(
                    [["public.utf8-plain-text": Data(string.utf8)]],
                    ClipCapture.textKind(for: string)
                )
            }
        }
    }

    /// Bytes to characters.
    ///
    /// `public.utf8-plain-text` and `public.file-url` are UTF-8 by definition, but the
    /// older `public.plain-text` says nothing about its encoding and what an AppKit text
    /// view writes is usually UTF-16. A byte-order mark is the only reliable way to tell,
    /// and it has to be checked first: UTF-16 text of ASCII characters decodes as valid
    /// UTF-8 full of nulls rather than failing.
    private static func text(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .utf16)
    }
}
