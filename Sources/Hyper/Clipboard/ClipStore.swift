import AppKit
import Foundation
import os

/// On-disk clipboard history.
///
/// Layout, under `~/.local/share/hyper/clipboard/`:
///
///     index.json        every record's metadata, in newest-first order
///     data/<uuid>.plist the pasteboard payload for one record
///     thumbs/<uuid>.png a downscaled preview for image records
///
/// The index is small enough to keep entirely in memory and to rewrite atomically, so
/// there is no database and nothing to migrate — and a curious user can read the whole
/// thing with `plutil` or `cat`. Payloads live in their own files because a single
/// screenshot can outweigh the entire rest of the history; keeping them out of the
/// index is what makes opening the panel instant no matter how long the history is.
///
/// Every mutating method is main-thread only. File writes for payloads happen on a
/// background queue, and the index write is debounced.
final class ClipStore {
    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.store")

    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/hyper/clipboard", isDirectory: true)

    /// Injectable so tests can run against a temporary directory instead of the real
    /// history.
    private let root: URL

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var thumbDirectory: URL { root.appendingPathComponent("thumbs", isDirectory: true) }

    private(set) var records: [ClipRecord] = []

    /// Bumped on every change so views can refresh without diffing the whole array.
    private(set) var generation: UInt64 = 0

    private let io = DispatchQueue(label: "com.indincys.hyper.clipstore", qos: .utility)
    private var flushWorkItem: DispatchWorkItem?
    private var thumbnailCache: [UUID: NSImage] = [:]

    var retentionDays = 30
    var maxItems = 1000

    init(root: URL = ClipStore.directory) {
        self.root = root
        createDirectories()
        loadIndex()
    }

    // MARK: - Disk layout

    private func createDirectories() {
        let fm = FileManager.default
        for url in [root, dataDirectory, thumbDirectory] {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                log.error("cannot create \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Blocks until every queued file operation has finished. Tests need it; the app
    /// never does, because nothing there waits on the disk.
    func waitForPendingWrites() {
        io.sync {}
    }

    private func payloadURL(_ id: UUID) -> URL {
        dataDirectory.appendingPathComponent("\(id.uuidString).plist")
    }

    private func thumbnailURL(_ id: UUID) -> URL {
        thumbDirectory.appendingPathComponent("\(id.uuidString).png")
    }

    // MARK: - Index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ClipRecord].self, from: data) else {
            // A corrupt index would otherwise take the whole history with it on every
            // launch. Move it aside once and start clean; the payload files stay put
            // so nothing is silently destroyed.
            log.error("clipboard index is unreadable; moving it aside")
            try? FileManager.default.moveItem(
                at: indexURL,
                to: indexURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            )
            return
        }
        records = decoded
        log.info("clipboard history loaded: \(self.records.count) entries")
    }

    /// Debounced: a burst of copies produces one write, not one per copy.
    private func scheduleFlush() {
        generation &+= 1
        flushWorkItem?.cancel()
        let snapshot = records
        let url = indexURL
        let item = DispatchWorkItem { [weak self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            guard let data = try? encoder.encode(snapshot) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self?.log.error("index write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        flushWorkItem = item
        io.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Writes the index immediately. Called on quit, where a debounced write would be
    /// cancelled by the process going away.
    func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            try encoder.encode(records).write(to: indexURL, options: .atomic)
            log.info("index flushed: \(self.records.count) entries")
        } catch {
            log.error("final index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Insert

    struct Insertion {
        var payload: ClipPayload
        var kind: ClipKind
        var oversized: Bool
        var byteSize: Int
        var sourceBundleID: String?
        var sourceName: String?
    }

    /// Adds a capture, or bumps the existing entry if the same thing was copied again.
    /// Returns the record that ended up at the top.
    @discardableResult
    func insert(_ insertion: Insertion) -> ClipRecord {
        let digest = ClipPayloadCoder.digest(insertion.payload)

        // Re-copying something already in the history should move it up, not add a
        // second identical row. Pinned state and the original source survive the bump.
        if let existing = records.firstIndex(where: { $0.digest == digest }) {
            var record = records[existing]
            record.createdAt = Date()
            records.remove(at: existing)
            insertSorted(record)
            scheduleFlush()
            log.info("re-copy of an existing entry; bumped \(record.id.uuidString, privacy: .public) to the top")
            return record
        }

        let id = UUID()
        var record = ClipRecord(
            id: id,
            createdAt: Date(),
            kind: insertion.kind,
            preview: ClipCapture.makePreview(kind: insertion.kind, payload: insertion.payload),
            digest: digest,
            byteSize: insertion.byteSize,
            sourceBundleID: insertion.sourceBundleID,
            sourceName: insertion.sourceName,
            oversized: insertion.oversized
        )

        if insertion.kind == .files {
            record.fileCount = ClipCapture.fileURLs(from: insertion.payload).count
        }

        var thumbnailData: Data?
        if insertion.kind == .image, let image = ClipCapture.image(from: insertion.payload) {
            let size = image.representationPixelSize
            record.pixelWidth = size.width
            record.pixelHeight = size.height
            // Sized for the panel's preview pane, not the 34pt row — a thumbnail that
            // only suits the row gets visibly upscaled the moment it is selected.
            if let data = image.downscaledPNG(maxDimension: 720) {
                thumbnailData = data
                record.hasThumbnail = true
            }
        }

        insertSorted(record)

        let payloadData = record.oversized ? nil : ClipPayloadCoder.encode(insertion.payload)
        if payloadData == nil, !record.oversized {
            log.error("payload could not be serialised for \(id.uuidString, privacy: .public) — the entry will not be pastable")
        }
        let payloadURL = payloadURL(id)
        let thumbURL = thumbnailURL(id)
        io.async { [log] in
            // A failed payload write leaves an index entry that pastes nothing, which
            // is exactly the kind of silent failure that is impossible to diagnose
            // later without a line in the log.
            if let payloadData {
                do {
                    try payloadData.write(to: payloadURL, options: .atomic)
                } catch {
                    log.error("payload write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if let thumbnailData {
                do {
                    try thumbnailData.write(to: thumbURL, options: .atomic)
                } catch {
                    log.error("thumbnail write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        log.info("recorded \(insertion.kind.rawValue, privacy: .public) entry, \(insertion.byteSize) bytes, from \(insertion.sourceName ?? "unknown", privacy: .public)")

        sweep()
        scheduleFlush()
        return record
    }

    /// Pinned entries float to the top; everything else is newest-first.
    private func insertSorted(_ record: ClipRecord) {
        records.append(record)
        records.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: - Read

    func record(id: UUID) -> ClipRecord? {
        records.first { $0.id == id }
    }

    /// Where an entry's payload lives. Exposed so a background reader can load one
    /// without holding on to the store, none of whose state is safe off the main thread.
    func payloadLocation(for id: UUID) -> URL { payloadURL(id) }

    func payload(for id: UUID) -> ClipPayload? {
        do {
            let data = try Data(contentsOf: payloadURL(id))
            guard let payload = ClipPayloadCoder.decode(data) else {
                log.error("payload for \(id.uuidString, privacy: .public) is not a readable plist")
                return nil
            }
            return payload
        } catch {
            log.error("payload for \(id.uuidString, privacy: .public) could not be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func thumbnail(for record: ClipRecord) -> NSImage? {
        guard record.hasThumbnail else { return nil }
        if let cached = thumbnailCache[record.id] { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(record.id)) else { return nil }
        // Bounded so scrolling a thousand screenshots cannot grow without limit.
        if thumbnailCache.count > 120 { thumbnailCache.removeAll(keepingCapacity: true) }
        thumbnailCache[record.id] = image
        return image
    }

    func search(_ query: String, kind: ClipKind?, pinnedOnly: Bool) -> [ClipRecord] {
        var result = records
        if pinnedOnly { result = result.filter(\.pinned) }
        if let kind { result = result.filter { $0.kind == kind } }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return result }
        return result.filter {
            $0.preview.localizedCaseInsensitiveContains(trimmed)
                || ($0.sourceName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    // MARK: - Mutate

    func togglePin(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        record.pinned.toggle()
        records.remove(at: index)
        insertSorted(record)
        scheduleFlush()
    }

    func delete(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        thumbnailCache[id] = nil
        removeFiles(for: [id])
        scheduleFlush()
    }

    /// Clears everything except pinned entries, which is what "clear history" means to
    /// someone who deliberately starred a few things.
    func clearUnpinned() {
        let doomed = records.filter { !$0.pinned }.map(\.id)
        records.removeAll { !$0.pinned }
        for id in doomed { thumbnailCache[id] = nil }
        removeFiles(for: doomed)
        scheduleFlush()
    }

    func clearAll() {
        let doomed = records.map(\.id)
        records.removeAll()
        thumbnailCache.removeAll()
        removeFiles(for: doomed)
        scheduleFlush()
    }

    private func removeFiles(for ids: [UUID]) {
        let payloads = ids.map(payloadURL)
        let thumbs = ids.map(thumbnailURL)
        io.async {
            let fm = FileManager.default
            for url in payloads + thumbs { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Retention

    /// Rolling eviction rather than a periodic wipe: age *and* count, whichever bites
    /// first, and pinned entries are exempt from both. A scheduled "delete everything"
    /// would take the things the user deliberately kept along with the noise.
    func sweep() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        var doomed: [UUID] = []

        records.removeAll { record in
            guard !record.pinned, record.createdAt < cutoff else { return false }
            doomed.append(record.id)
            return true
        }

        let unpinnedCount = records.reduce(0) { $0 + ($1.pinned ? 0 : 1) }
        if unpinnedCount > maxItems {
            var over = unpinnedCount - maxItems
            // Oldest first, so walk from the back.
            for index in records.indices.reversed() where over > 0 {
                guard !records[index].pinned else { continue }
                doomed.append(records[index].id)
                records.remove(at: index)
                over -= 1
            }
        }

        guard !doomed.isEmpty else { return }
        for id in doomed { thumbnailCache[id] = nil }
        removeFiles(for: doomed)
        log.info("clipboard sweep evicted \(doomed.count) entries")
        scheduleFlush()
    }

    /// Deletes payload and thumbnail files with no matching record, which is how the
    /// store recovers from a crash between writing a payload and writing the index.
    func reconcileOrphans() {
        let live = Set(records.map(\.id.uuidString))
        let dirs = [dataDirectory, thumbDirectory]
        io.async {
            let fm = FileManager.default
            for dir in dirs {
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names {
                    let stem = (name as NSString).deletingPathExtension
                    guard !live.contains(stem) else { continue }
                    try? fm.removeItem(at: dir.appendingPathComponent(name))
                }
            }
        }
    }

    /// Bytes on disk, for the settings screen. Computed off the main thread.
    func diskUsage(completion: @escaping (Int64) -> Void) {
        let dirs = [dataDirectory, thumbDirectory, Self.directory]
        io.async {
            let fm = FileManager.default
            var total: Int64 = 0
            for dir in dirs {
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names {
                    let path = dir.appendingPathComponent(name).path
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let size = attrs[.size] as? NSNumber else { continue }
                    total += size.int64Value
                }
            }
            DispatchQueue.main.async { completion(total) }
        }
    }
}

// MARK: - Image helpers

extension NSImage {
    /// The size in real pixels. `NSImage.size` is in points and lies about a Retina
    /// screenshot by a factor of two.
    var representationPixelSize: (width: Int, height: Int) {
        var width = 0
        var height = 0
        for rep in representations {
            width = max(width, rep.pixelsWide)
            height = max(height, rep.pixelsHigh)
        }
        if width == 0 || height == 0 {
            return (Int(size.width.rounded()), Int(size.height.rounded()))
        }
        return (width, height)
    }

    func downscaledPNG(maxDimension: CGFloat) -> Data? {
        let pixels = representationPixelSize
        guard pixels.width > 0, pixels.height > 0 else { return nil }

        let scale = min(1, maxDimension / CGFloat(max(pixels.width, pixels.height)))
        let target = NSSize(
            width: max(1, (CGFloat(pixels.width) * scale).rounded()),
            height: max(1, (CGFloat(pixels.height) * scale).rounded())
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target),
             from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
