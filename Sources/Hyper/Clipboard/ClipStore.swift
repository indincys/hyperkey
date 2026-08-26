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
///     search/<uuid>.txt the plain-text body, for full-text search
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
    private var searchDirectory: URL { root.appendingPathComponent("search", isDirectory: true) }

    private(set) var records: [ClipRecord] = []

    /// Bumped on every change so views can refresh without diffing the whole array.
    private(set) var generation: UInt64 = 0

    private let io = DispatchQueue(label: "com.indincys.hyper.clipstore", qos: .utility)
    private var flushWorkItem: DispatchWorkItem?

    /// `NSCache` rather than a dictionary: it evicts the least recently used entry once
    /// the count limit is reached instead of throwing the whole cache away, and it drops
    /// everything on its own under memory pressure. Decoded PNGs are the single largest
    /// thing this process holds, so that second property is worth more than the first.
    private let thumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 150
        return cache
    }()

    /// Full-text bodies, main-thread only like every other piece of mutable state here.
    /// Read out through `searchSnapshot()` when a scan needs to happen off the main
    /// thread — the dictionary is copy-on-write, so handing it over costs a retain.
    private var searchIndex: [UUID: ClipSearchEntry] = [:]

    /// A history's worth of sidecar files takes a moment to read; the panel wants to
    /// know when it can search the whole thing rather than just the previews.
    var onSearchIndexLoaded: (() -> Void)?

    /// The ids `sweep` just evicted. Retention is the one deletion path the store drives
    /// on its own — every other one goes through a caller that knows what it deleted —
    /// and the paste queue holds ids rather than payloads, so an eviction nobody reports
    /// leaves it counting rows that no longer exist and dispensing nothing when asked.
    /// Called synchronously, on the main thread, at the end of the sweep.
    var onEvicted: (([UUID]) -> Void)?

    /// Reads that happen once at launch. Separate from `io` so neither the index read
    /// nor the sidecar scan can sit in front of the payload write for something the
    /// user just copied. Serial, so the two reads never compete with each other either.
    private let loadQueue = DispatchQueue(label: "com.indincys.hyper.clipstore.load", qos: .utility)

    /// Whether `records` reflects what is on disk. False for the first moments after
    /// launch, while the index is still being read.
    private(set) var isLoaded = false
    private var loadWaiters: [() -> Void] = []

    var retentionDays = 30
    var maxItems = 1000

    init(root: URL = ClipStore.directory) {
        self.root = root
        createDirectories()
        loadIndex()
    }

    /// Runs `body` on the main thread once the index is in memory — immediately if it
    /// already is. Anything that reads `records` at launch has to go through this,
    /// because the read from disk no longer finishes before `init` returns.
    func whenLoaded(_ body: @escaping () -> Void) {
        guard !isLoaded else {
            body()
            return
        }
        loadWaiters.append(body)
    }

    // MARK: - Disk layout

    private func createDirectories() {
        let fm = FileManager.default
        for url in [root, dataDirectory, thumbDirectory, searchDirectory] {
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
        loadQueue.sync {}
        io.sync {}
    }

    private func payloadURL(_ id: UUID) -> URL {
        dataDirectory.appendingPathComponent("\(id.uuidString).plist")
    }

    private func thumbnailURL(_ id: UUID) -> URL {
        thumbDirectory.appendingPathComponent("\(id.uuidString).png")
    }

    private func searchTextURL(_ id: UUID) -> URL {
        searchDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    // MARK: - Index

    /// A thousand entries is about a megabyte of JSON; reading and decoding that on the
    /// main thread is a visible pause on a hotkey-driven app whose whole promise is that
    /// it is there the instant you ask for it. So the read and the decode happen in the
    /// background and only the array assignment comes back to the main thread, which
    /// keeps the "mutating state is main-thread only" rule intact.
    ///
    /// Nothing waits on this: capture works from the first moment, and the panel shows
    /// an empty list for the handful of milliseconds before `historyChanged` refreshes
    /// it. Everything that reads `records` at launch goes through `whenLoaded`.
    private func loadIndex() {
        let url = indexURL
        loadQueue.async { [weak self, log] in
            var decoded: [ClipRecord] = []
            if let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let records = try? decoder.decode([ClipRecord].self, from: data) {
                    decoded = records
                } else {
                    // A corrupt index would otherwise take the whole history with it on
                    // every launch. Move it aside once and start clean; the payload
                    // files stay put so nothing is silently destroyed.
                    log.error("clipboard index is unreadable; moving it aside")
                    try? FileManager.default.moveItem(
                        at: url,
                        to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                    )
                }
            }
            DispatchQueue.main.async {
                self?.adoptLoadedIndex(decoded)
            }
        }
    }

    private func adoptLoadedIndex(_ decoded: [ClipRecord]) {
        let captured = records
        var mergedCount = 0

        if captured.isEmpty {
            records = decoded
            generation &+= 1
        } else {
            // Something was copied while the read was in flight, and it was recorded
            // under a brand-new id because the history it might already be in had not
            // arrived yet.
            //
            // Where the capture is genuinely new it simply joins the list. Where it
            // matches a record on disk by digest, the *disk* record wins: it owns the
            // identity everything else refers to — the paste queue holds its id, and its
            // pinned flag, source and thumbnail are things the fresh capture cannot know.
            // Only `createdAt` moves over, which is exactly the bump `insert` performs
            // when the same thing is copied twice. Keeping the capture instead would
            // strip the pin, orphan the disk record's files for `reconcileOrphans` to
            // delete, and let `queue.prune` drop the id the queue was holding.
            var merged = decoded
            var indexByDigest: [String: Int] = [:]
            for (index, record) in merged.enumerated() { indexByDigest[record.digest] = index }

            // The capture already wrote payload and search sidecars under its own id.
            // Those files belong to no record once the capture is discarded, so they go
            // now; the disk record's own files are untouched.
            var discarded: [UUID] = []
            var adoptedSearch: [(UUID, ClipSearchEntry)] = []

            for capture in captured {
                if let index = indexByDigest[capture.digest] {
                    merged[index].createdAt = capture.createdAt
                    if let entry = searchIndex[capture.id] {
                        adoptedSearch.append((merged[index].id, entry))
                    }
                    discarded.append(capture.id)
                } else {
                    indexByDigest[capture.digest] = merged.count
                    merged.append(capture)
                }
            }

            records = merged
            sortRecords()
            if !discarded.isEmpty { removeFiles(for: discarded) }
            // Re-hung after `removeFiles`, which clears the discarded id's entry: the
            // body is the same text either way, so the row stays searchable immediately
            // instead of waiting for the sidecar scan.
            for (id, entry) in adoptedSearch { searchIndex[id] = entry }
            mergedCount = captured.count
        }

        isLoaded = true
        log.info("clipboard history loaded: \(self.records.count) entries")

        // Only now, with `isLoaded` true, may anything write index.json — and the merged
        // list is the first thing that has to be written, because what is on disk at this
        // moment is whatever the launch-window capture left there.
        if mergedCount > 0 {
            scheduleFlush()
            log.info("index load merged with \(mergedCount) entries captured during launch")
        }

        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter() }

        // Strictly after the index, because it walks one sidecar file per record — and
        // strictly after the waiters, because the first sweep runs in one of them. Started
        // any earlier, the scan would capture ids that are about to be evicted and then
        // merge their text back in, leaving zombie entries in memory for the rest of the
        // session and rewriting sidecars for records that no longer exist.
        loadSearchIndex()
    }

    // MARK: - Search index

    /// Reads the sidecar text for every record in the background, building it from the
    /// payload for anything recorded before this existed. Nothing waits on it: until it
    /// lands, `search` falls back to previews and source names, which is exactly what
    /// the previous version did — so a large history opens the panel just as fast.
    private func loadSearchIndex() {
        let ids = records.map(\.id)
        guard !ids.isEmpty else { return }
        // Bound URLs rather than `self`'s accessors, or the closure would hold the
        // store alive for the length of the scan.
        let searchDir = searchDirectory
        let dataDir = dataDirectory
        let textURL = { (id: UUID) in searchDir.appendingPathComponent("\(id.uuidString).txt") }
        let payloadURL = { (id: UUID) in dataDir.appendingPathComponent("\(id.uuidString).plist") }

        loadQueue.async { [weak self, log] in
            var loaded: [UUID: ClipSearchEntry] = [:]
            var rebuilt: [(UUID, String)] = []

            for id in ids {
                if let text = try? String(contentsOf: textURL(id), encoding: .utf8),
                   let entry = ClipSearch.makeEntry(text: text) {
                    loaded[id] = entry
                    continue
                }
                // Pre-upgrade entry. Plain text only — unpacking RTF or HTML goes
                // through AppKit, which is not allowed here.
                guard let data = try? Data(contentsOf: payloadURL(id)),
                      let payload = ClipPayloadCoder.decode(data),
                      let text = ClipCapture.plainTextOnly(from: payload),
                      let entry = ClipSearch.makeEntry(text: text)
                else { continue }
                loaded[id] = entry
                rebuilt.append((id, entry.text))
            }

            for (id, text) in rebuilt {
                do {
                    try Data(text.utf8).write(to: textURL(id), options: .atomic)
                } catch {
                    log.error("search text backfill failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if !rebuilt.isEmpty {
                log.info("search index backfilled for \(rebuilt.count) older entries")
            }

            guard !loaded.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // A record can be evicted while the scan is in flight — the hourly sweep,
                // or a capture that pushes the history over its cap. Merging its text back
                // in would leave a body of up to 32KB in memory, attached to an id nothing
                // can ever show again, until the process quits.
                let live = Set(self.records.map(\.id))
                let surviving = loaded.filter { live.contains($0.key) }
                // Anything copied while this ran was indexed from a live payload and is
                // therefore better than what came off disk; keep it.
                self.searchIndex.merge(surviving) { current, _ in current }
                self.log.info("search index ready: \(self.searchIndex.count) entries")
                self.onSearchIndexLoaded?()
            }
        }
    }

    /// The body a record is searched by. Called on the main thread from `insert`, which
    /// is why it can afford `plainText(from:)` and its AppKit-backed RTF/HTML fallback.
    private func searchText(kind: ClipKind, payload: ClipPayload) -> String? {
        switch kind {
        case .image:
            return nil
        case .files:
            let paths = ClipCapture.fileURLs(from: payload).map(\.path)
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        case .text, .richText, .url, .color:
            return ClipCapture.plainText(from: payload)
        }
    }

    /// Debounced: a burst of copies produces one write, not one per copy.
    ///
    /// No write of any kind happens before the index has been read back. `records` then
    /// holds at most what was captured in the launch window, and writing that out would
    /// replace the entire history on disk with a single row — after which the next
    /// launch's `reconcileOrphans` deletes every payload behind the rows that vanished.
    /// Nothing is lost by skipping: `adoptLoadedIndex` merges those captures into the
    /// loaded index and flushes once, afterwards.
    private func scheduleFlush() {
        generation &+= 1
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard isLoaded else { return }
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
    ///
    /// Guarded like `scheduleFlush`, and for a case that is anything but theoretical:
    /// quitting in the first moments after launch used to run this against an empty
    /// `records`, truncate index.json, and take the whole history's payloads with it on
    /// the next start. Before the load there is by definition nothing to save.
    func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard isLoaded else {
            log.info("index flush skipped: the history has not been read back yet")
            return
        }
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

        // Resolved once, here, rather than on every redraw: unarchiving an NSColor is
        // not expensive, but the payload it lives in is a separate file on disk.
        if insertion.kind == .color {
            record.colorHex = ClipCapture.colorHex(from: insertion.payload)
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

        // Indexed even when the payload is over the cap: the text is a few kilobytes at
        // most, and being able to find the thing you copied is half of why the row is
        // still in the history at all.
        var searchTextData: Data?
        if let text = searchText(kind: insertion.kind, payload: insertion.payload),
           let entry = ClipSearch.makeEntry(text: text) {
            searchIndex[id] = entry
            searchTextData = Data(entry.text.utf8)
        }

        let payloadData = record.oversized ? nil : ClipPayloadCoder.encode(insertion.payload)
        if payloadData == nil, !record.oversized {
            log.error("payload could not be serialised for \(id.uuidString, privacy: .public) — the entry will not be pastable")
        }
        let payloadURL = payloadURL(id)
        let thumbURL = thumbnailURL(id)
        let searchURL = searchTextURL(id)
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
            if let searchTextData {
                // Losing this only costs full-text search for one entry, so it is worth
                // a log line but never worth failing the capture over.
                do {
                    try searchTextData.write(to: searchURL, options: .atomic)
                } catch {
                    log.error("search text write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
        sortRecords()
    }

    private func sortRecords() {
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
        let key = record.id as NSUUID
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(record.id)) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Records and text index together, for a caller that wants to run the scan off the
    /// main thread. Must be taken here, on the main thread; both halves are
    /// copy-on-write, so the hand-off is two retains and never a deep copy.
    func searchSnapshot() -> ClipSearchSnapshot {
        ClipSearchSnapshot(records: records, index: searchIndex)
    }

    /// Kept synchronous — callers that only ever filter a short list, and the tests, do
    /// not need the ceremony. The panel goes through `searchSnapshot()` instead so a
    /// full-text scan cannot stutter typing.
    func search(_ query: String, kind: ClipKind?, pinnedOnly: Bool) -> [ClipRecord] {
        let request = ClipSearchRequest(
            terms: ClipSearch.terms(from: query), kind: kind, pinnedOnly: pinnedOnly
        )
        return ClipSearch.run(request, in: searchSnapshot()).records
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

    /// Replaces a text entry's body in place, keeping its id, its position and its
    /// pinned state — an edit is a correction to something already in the history, not a
    /// new capture, and a row that jumped to the top on every typo fix would be useless.
    ///
    /// Everything derived from the payload has to move with it. The digest above all: it
    /// is what collapses a re-copy onto an existing row, so leaving the old one behind
    /// would mean copying the *pre-edit* text again quietly restores it here.
    ///
    /// The payload is written synchronously rather than on `io`, because the caller's
    /// next move is usually to paste this entry and the paste path reads the payload back
    /// off disk. A few kilobytes of typed text on a deliberate, once-per-edit action is
    /// not the place to be clever about blocking.
    @discardableResult
    func updateText(id: UUID, newText: String) -> ClipRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }

        // One key covers it: `NSPasteboard.PasteboardType.string` *is*
        // "public.utf8-plain-text", which is the type every reader here looks for first.
        let payload: ClipPayload = [["public.utf8-plain-text": Data(newText.utf8)]]
        // Only ever `.text` or `.url` — a link edited into prose should stop filtering as
        // a link, and prose edited into a link should start.
        let kind = ClipCapture.textKind(for: newText)

        var record = records[index]
        record.kind = kind
        record.preview = ClipCapture.makePreview(kind: kind, payload: payload)
        record.digest = ClipPayloadCoder.digest(payload)
        record.byteSize = ClipPayloadCoder.byteSize(payload)
        // The body is now whatever was typed, which by definition fits: an entry that had
        // been recorded as metadata-only becomes pastable again.
        record.oversized = false
        records[index] = record

        var searchData: Data?
        if let entry = ClipSearch.makeEntry(text: newText) {
            searchIndex[id] = entry
            searchData = Data(entry.text.utf8)
        } else {
            searchIndex[id] = nil
        }

        if let data = ClipPayloadCoder.encode(payload) {
            do {
                try data.write(to: payloadURL(id), options: .atomic)
            } catch {
                log.error("edited payload write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let searchURL = searchTextURL(id)
        io.async { [log] in
            do {
                if let searchData {
                    try searchData.write(to: searchURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: searchURL)
                }
            } catch {
                log.error("edited search text write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        scheduleFlush()
        return record
    }

    func delete(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        removeFiles(for: [id])
        scheduleFlush()
    }

    /// Clears everything except pinned entries, which is what "clear history" means to
    /// someone who deliberately starred a few things.
    func clearUnpinned() {
        let doomed = records.filter { !$0.pinned }.map(\.id)
        records.removeAll { !$0.pinned }
        removeFiles(for: doomed)
        scheduleFlush()
    }

    func clearAll() {
        let doomed = records.map(\.id)
        records.removeAll()
        removeFiles(for: doomed)
        scheduleFlush()
    }

    /// The one place every deletion path funnels through, so neither the in-memory
    /// search text nor a cached thumbnail can outlive the record it belongs to.
    private func removeFiles(for ids: [UUID]) {
        for id in ids {
            searchIndex[id] = nil
            thumbnailCache.removeObject(forKey: id as NSUUID)
        }
        let payloads = ids.map(payloadURL)
        let thumbs = ids.map(thumbnailURL)
        let searchTexts = ids.map(searchTextURL)
        io.async {
            let fm = FileManager.default
            for url in payloads + thumbs + searchTexts { try? fm.removeItem(at: url) }
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
        removeFiles(for: doomed)
        log.info("clipboard sweep evicted \(doomed.count) entries")
        scheduleFlush()
        // Last, so the store is fully consistent before anyone reacts to it.
        onEvicted?(doomed)
    }

    /// Deletes payload and thumbnail files with no matching record, which is how the
    /// store recovers from a crash between writing a payload and writing the index.
    func reconcileOrphans() {
        let live = Set(records.map(\.id.uuidString))
        let dirs = [dataDirectory, thumbDirectory, searchDirectory]
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

    /// What the settings screen shows: the shape of the history, and where its bytes are.
    ///
    /// The counts come from `records`, which the caller already has to be on the main
    /// thread to read; the three directory sizes are the part worth a background pass.
    /// Split by directory rather than reported as one number because the three grow for
    /// very different reasons — a screenshot-heavy history is mostly `data/`, and a
    /// `thumbs/` or `search/` that has outgrown it means orphans to clean up.
    struct Statistics: Equatable {
        var counts: [ClipKind: Int] = [:]
        var total = 0
        var pinned = 0
        var payloadBytes: Int64 = 0
        var thumbnailBytes: Int64 = 0
        var searchBytes: Int64 = 0

        var diskBytes: Int64 { payloadBytes + thumbnailBytes + searchBytes }
    }

    /// Main-thread only, like every other read of `records`; `completion` comes back on
    /// the main thread too. Queued behind whatever `io` is already doing, so a refresh
    /// asked for right after `reconcileOrphans` measures what the cleanup left behind.
    func statistics(completion: @escaping (Statistics) -> Void) {
        var counted = Statistics()
        counted.total = records.count
        for record in records {
            counted.counts[record.kind, default: 0] += 1
            if record.pinned { counted.pinned += 1 }
        }

        let dataDir = dataDirectory
        let thumbDir = thumbDirectory
        let searchDir = searchDirectory
        let snapshot = counted
        io.async {
            var stats = snapshot
            stats.payloadBytes = ClipStore.byteSize(of: dataDir)
            stats.thumbnailBytes = ClipStore.byteSize(of: thumbDir)
            stats.searchBytes = ClipStore.byteSize(of: searchDir)
            DispatchQueue.main.async { completion(stats) }
        }
    }

    private static func byteSize(of directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        for name in names {
            let path = directory.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else { continue }
            total += size.int64Value
        }
        return total
    }

    /// Bytes on disk, for the settings screen. Computed off the main thread.
    func diskUsage(completion: @escaping (Int64) -> Void) {
        let dirs = [dataDirectory, thumbDirectory, searchDirectory, Self.directory]
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
