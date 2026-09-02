import CryptoKit
import Foundation
import os

/// The searchable body of one entry, plus its romanised forms.
///
/// `preview` only holds the first 400 collapsed characters, so anything copied out of a
/// document is unfindable by the part of it that matters. This is the rest of the text,
/// kept next to the payload in `search/<uuid>.txt` and mirrored in memory.
struct ClipSearchEntry: Codable, Equatable, Sendable {
    /// Plain text, capped at `ClipSearch.maxTextLength` characters.
    let text: String
    /// Mandarin pinyin with the syllable breaks removed — "剪贴板" becomes "jiantieban",
    /// which is what someone typing without pauses actually produces. Empty when the
    /// text holds no CJK.
    let pinyin: String
    /// First letter of every syllable: "jtb" for "剪贴板".
    let initials: String
}

/// A prepared query. Splitting once and reusing the terms keeps the per-record work in
/// the filter loop down to substring searches.
struct ClipSearchRequest: Sendable {
    var terms: [String]
    var kind: ClipKind?
    var pinnedOnly: Bool
    var query: ClipQuery?
    var cancellation: ClipSearchCancellationToken?

    init(terms: [String], kind: ClipKind? = nil, pinnedOnly: Bool) {
        self.terms = terms
        self.kind = kind
        self.pinnedOnly = pinnedOnly
        query = nil
        cancellation = nil
    }

    init(query: ClipQuery, cancellation: ClipSearchCancellationToken? = nil) {
        terms = query.highlightTerms
        kind = query.kinds.count == 1 ? query.kinds.first : nil
        pinnedOnly = query.pinned == true
        self.query = query
        self.cancellation = cancellation
    }
}

/// Records plus the text index, taken together on the main thread so the actual scan
/// can run anywhere. Both members are copy-on-write, so this costs two retains rather
/// than a copy of the whole history.
struct ClipSearchSnapshot: Sendable {
    var records: [ClipRecord]
    var index: [UUID: ClipSearchEntry]
    var invertedIndex: ClipSearchIndex?
    var queuedIDs: Set<UUID>

    init(
        records: [ClipRecord], index: [UUID: ClipSearchEntry],
        invertedIndex: ClipSearchIndex? = nil, queuedIDs: Set<UUID> = []
    ) {
        self.records = records
        self.index = index
        self.invertedIndex = invertedIndex
        self.queuedIDs = queuedIDs
    }
}

enum ClipSearchMatchKind: String, Codable, Equatable, Sendable {
    case exact, prefix, substring, phrase, source, pinyin, initials, fuzzy
}

struct ClipSearchMatchExplanation: Codable, Equatable, Sendable {
    var term: String
    var kind: ClipSearchMatchKind
    /// UTF-16 coordinates into the visible preview or indexed body. Nil for romanised
    /// and fuzzy evidence, where `matchedText` is the honest explanation.
    var utf16Range: NSRange?
    var matchedText: String?
}

struct ClipSearchOutcome: Sendable {
    var records: [ClipRecord]
    /// Echoed back so the view highlights exactly what this result set was filtered by,
    /// and not whatever has since been typed into the field.
    var terms: [String]
    /// Snippet of surrounding text for rows whose only hit is past the preview.
    var contexts: [UUID: String]
    var cancelled: Bool
    var matchExplanations: [UUID: [ClipSearchMatchExplanation]]

    init(
        records: [ClipRecord], terms: [String], contexts: [UUID: String],
        cancelled: Bool = false,
        matchExplanations: [UUID: [ClipSearchMatchExplanation]] = [:]
    ) {
        self.records = records
        self.terms = terms
        self.contexts = contexts
        self.cancelled = cancelled
        self.matchExplanations = matchExplanations
    }
}

final class ClipSearchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
}

/// A compact, versioned inverted index split by a stable UUID slot. Each segment is an
/// independent recovery and persistence unit: an edit rewrites one small authenticated
/// file, and damage to that file never makes a record or another segment disappear.
struct ClipSearchIndex: Sendable {
    static let formatVersion = 5
    static let segmentCount = 16
    static let maximumTokensPerDocument = 2_048
    static let maximumTokenLength = 128
    static let maximumResidentBytes = 256 * 1024 * 1024
    static let maximumBuildBatchDocuments = 64
    // Three-grams retain typo recall; five-grams stop high-cardinality identifiers whose
    // individual trigrams all occur elsewhere from becoming false candidates. Both are
    // strict q-gram lower-bound filters, so the second layer never weakens the verifier.
    // The combined 12KiB is charged to the same global resident budget.
    private static let gram3FilterByteCount = 4 * 1024
    private static let gram5FilterByteCount = 8 * 1024
    static let gramFilterByteCount = gram3FilterByteCount + gram5FilterByteCount
    /// Conservative live-allocation charge for a unique Swift Dictionary bucket, token
    /// String, posting Array and UUID relationship. High-cardinality measurements showed
    /// the old 160-byte paper estimate retained 5–7x more physical memory than charged.
    /// Postings are only an acceleration layer; the q-gram/verifier path stays complete
    /// when this budget admits fewer of them.
    static let minimumPostingBytes = 2_048

    /// Conservative per-entry charges for the runtime structures that hold the index
    /// together. Deliberately larger than the bare value widths: Swift's Dictionary and
    /// Set keep spare capacity, and undercharging here is what let the tombstone slack
    /// go unnoticed in the first place.
    static let gramSlotBytes = 24
    static let gramOffsetBytes = 64
    static let freeSlotBytes = 8
    static let documentIDBytes = 48
    /// What admitting one more document adds to `gramTableOverheadBytes`.
    static let perDocumentOverheadBytes = gramSlotBytes + gramOffsetBytes + documentIDBytes

    /// Headroom for the largest one-slot materialisation used by persistence and for a
    /// bounded build batch. Keeping it outside the steady-state capacity makes the
    /// advertised 256MiB ceiling apply to real transitions, not only the final counter.
    private static func transientReserve(for limit: Int) -> Int {
        min(16 * 1024 * 1024, max(64 * 1024, limit / 16))
    }

    private static let log = Logger(
        subsystem: Hyper.subsystem, category: "clipboard.search-index"
    )

    enum Failure: Error, Equatable {
        case malformed
        case unsupportedVersion(Int)
        case wrongSlot(expected: Int, actual: Int)
        case budgetExceeded
    }

    struct Document: Codable, Equatable, Sendable {
        var recordDigest: String
        var entryDigest: String
        var tokens: [String]
        var overflowed: Bool
        /// Includes the external `searchIndex` dictionary/key and all three String
        /// values. Persisting the charge makes a restored segment obey the same budget.
        var bodyResidentBytes: Int
        /// Fixed-size character 3-gram Bloom layer over every token, including tokens
        /// beyond `maximumTokensPerDocument`. False positives are allowed; false
        /// negatives are not. This keeps overflow rows out of the 32KiB verifier scan.
        var gramFilter: Data
    }

    struct Segment: Codable, Equatable, Sendable {
        var version = ClipSearchIndex.formatVersion
        var slot: Int
        var documents: [UUID: Document]
        var postings: [String: [UUID]]

        var documentCount: Int { documents.count }

        func contains(recordID: UUID, recordDigest: String, entry: ClipSearchEntry) -> Bool {
            guard let document = documents[recordID] else { return false }
            return document.recordDigest == recordDigest
                && document.entryDigest == ClipSearchIndex.digest(entry)
        }
    }

    /// Resident filters are packed by slot. Five thousand individual `Data` allocations
    /// made the candidate pass pointer-chase ~40MiB and took 80–600ms in debug builds;
    /// the same bytes in one table are sequential and stay inside the identical budget.
    ///
    /// Slots are addressed through `offsets` and freed with a tombstone rather than by
    /// splicing the packed bytes. Locating a filter used to be a linear `firstIndex(of:)`
    /// over the slot's ids and removing one moved every later filter down by 12KiB — an
    /// O(segment) memmove for a single deleted row. Both are now O(1), and the stale
    /// bytes are reclaimed in one pass when a quarter of the table is tombstoned.
    private struct GramTable: Sendable {
        /// One entry per packed slot. `nil` marks a tombstone whose bytes are stale and
        /// which every reader skips.
        var ids: [UUID?]
        var offsets: [UUID: Int]
        var freeSlots: [Int]
        var bytes: Data

        init(ids: [UUID], bytes: Data) {
            self.ids = ids
            self.bytes = bytes
            var offsets: [UUID: Int] = [:]
            offsets.reserveCapacity(ids.count)
            for (offset, id) in ids.enumerated() { offsets[id] = offset }
            self.offsets = offsets
            freeSlots = []
        }

        var liveCount: Int { offsets.count }

        /// Tombstoned slots stay resident and are charged to the same budget as
        /// everything else, so the ceiling on wasted bytes is a real memory ceiling
        /// rather than an aesthetic one. A tenth of the table is the point where one
        /// repack is cheaper than carrying the slack.
        var shouldCompact: Bool {
            !freeSlots.isEmpty && freeSlots.count * 10 >= ids.count
        }

        /// Bytes this table holds that the per-document estimate does not describe:
        /// tombstoned filter slots, the slot array, the offset map and the free list.
        var overheadBytes: Int {
            let live = liveCount
            return max(0, bytes.count - live * ClipSearchIndex.gramFilterByteCount)
                + ids.count * ClipSearchIndex.gramSlotBytes
                + live * ClipSearchIndex.gramOffsetBytes
                + freeSlots.count * ClipSearchIndex.freeSlotBytes
        }
    }

    private(set) var segments: [Int: Segment]
    private var gramTables: [Int: GramTable]
    /// Maintained incrementally. Rebuilding it per search meant a `flatMap` plus a fresh
    /// 5,000-element Set on every keystroke, for a value that only changes when the
    /// index does.
    private(set) var documentIDs: Set<UUID> = []
    /// The part of the resident total that belongs to the packed filter tables and to
    /// this cached id set rather than to any one document. Tombstoning a slot leaves its
    /// 12KiB in memory while `estimate(document:)` stops charging for it, and the offset
    /// map, free list and `documentIDs` are pure additions on top of that. Both are
    /// tracked here and folded into `estimatedResidentBytes`, so the advertised ceiling
    /// stays a statement about real memory.
    private(set) var gramTableOverheadBytes: Int = 0
    private(set) var estimatedResidentBytes: Int
    private(set) var accountedBodyBytes: Int
    private(set) var peakBuildResidentBytes: Int
    private var residentLimit: Int

    static let empty = ClipSearchIndex(
        segments: [:], gramTables: [:], estimatedResidentBytes: 0, accountedBodyBytes: 0,
        peakBuildResidentBytes: 0,
        residentLimit: maximumResidentBytes - transientReserve(for: maximumResidentBytes)
    )

    /// Bytes the packed filter tables hold right now, tombstoned slots included.
    /// Exposed so the accounting can be checked against the thing it describes.
    var residentFilterByteCount: Int {
        gramTables.values.reduce(0) { $0 + $1.bytes.count }
    }

    var postingCount: Int {
        segments.values.reduce(0) { total, segment in
            total + segment.postings.values.reduce(0) { $0 + $1.count }
        }
    }

    var overflowDocumentCount: Int {
        segments.values.reduce(0) { total, segment in
            total + segment.documents.values.filter(\.overflowed).count
        }
    }

    static func slot(for id: UUID) -> Int {
        let prefix = id.uuidString.prefix(2)
        return (Int(prefix, radix: 16) ?? 0) % segmentCount
    }

    static func build(
        records: [ClipRecord], entries: [UUID: ClipSearchEntry],
        maximumResidentBytes residentLimit: Int = maximumResidentBytes
    ) -> ClipSearchIndex {
        let searchable = records.filter { entries[$0.id] != nil }
        let bodyBytes = searchable.reduce(0) { total, record in
            total + (entries[record.id].map(estimateBody(entry:)) ?? 0)
        }
        var index = ClipSearchIndex(
            segments: [:], gramTables: [:], estimatedResidentBytes: bodyBytes,
            accountedBodyBytes: bodyBytes, peakBuildResidentBytes: bodyBytes,
            residentLimit: {
                let hardLimit = max(0, min(residentLimit, maximumResidentBytes))
                return max(0, hardLimit - transientReserve(for: hardLimit))
            }()
        )
        // Reserve every searchable body first. Filters are generated directly into one
        // packed allocation per slot; constructing 5,000 standalone Data values and then
        // compacting them left ~60MiB of allocator pages resident after the build.
        let overflowStructuralBytes = 512 + gramFilterByteCount + 64
        var accepted: [ClipRecord] = []
        accepted.reserveCapacity(searchable.count)
        var acceptedStructureBytes = 0
        // Reserved separately from the document charge because it is `refreshGramOverhead`
        // that actually applies it below. Counting it in both places would charge every
        // admitted document's slot, offset and id-set bytes twice.
        var acceptedOverheadBytes = 0
        for record in searchable {
            guard index.estimatedResidentBytes + acceptedStructureBytes
                    + acceptedOverheadBytes + overflowStructuralBytes
                    + perDocumentOverheadBytes <= index.residentLimit
            else { break }
            accepted.append(record)
            acceptedStructureBytes += overflowStructuralBytes
            acceptedOverheadBytes += perDocumentOverheadBytes
        }
        let grouped = Dictionary(grouping: accepted, by: { Self.slot(for: $0.id) })
            .sorted { $0.key < $1.key }
        let resultLock = NSLock()
        var preparedSlots: [(Int, Segment, GramTable)] = []
        preparedSlots.reserveCapacity(grouped.count)
        DispatchQueue.concurrentPerform(iterations: grouped.count) { offset in
            let (slot, slotRecords) = grouped[offset]
            let prepared = Self.makePackedOverflowSegment(
                slot: slot, records: slotRecords, entries: entries
            )
            resultLock.withLock { preparedSlots.append((slot, prepared.0, prepared.1)) }
        }
        for (slot, segment, table) in preparedSlots.sorted(by: { $0.0 < $1.0 }) {
            index.segments[slot] = segment
            index.gramTables[slot] = table
            index.documentIDs.formUnion(segment.documents.keys)
        }
        index.estimatedResidentBytes += acceptedStructureBytes
        // Before the postings phase, so what the tables and id set really cost is
        // subtracted from the budget the postings are then allowed to spend.
        index.refreshGramOverhead()
        index.peakBuildResidentBytes = max(
            index.peakBuildResidentBytes,
            index.estimatedResidentBytes + Self.transientReserve(
                for: min(residentLimit, Self.maximumResidentBytes)
            )
        )

        // Upgrade in bounded batches. The per-document tokenizer is capped by its share
        // of the actual remaining budget, so temporary prepared postings plus the live
        // index remain under the same ceiling even for a 5,000 × 2,048-unique-token corpus.
        var start = 0
        while start < searchable.count {
            let remaining = index.residentLimit - index.estimatedResidentBytes
            let worstSinglePosting = minimumPostingBytes + (2 * maximumTokenLength)
            let temporaryDocumentBytes = 512
            guard remaining >= worstSinglePosting + temporaryDocumentBytes else { break }
            let affordableCount = max(
                1, remaining / (worstSinglePosting + temporaryDocumentBytes)
            )
            let count = min(
                maximumBuildBatchDocuments, affordableCount, searchable.count - start
            )
            let batch = Array(searchable[start..<(start + count)])
            let postingBudgetPerDocument = (remaining - count * temporaryDocumentBytes) / count
            let resultLock = NSLock()
            var prepared: [(Int, UUID, Document)] = []
            prepared.reserveCapacity(batch.count)
            DispatchQueue.concurrentPerform(iterations: batch.count) { offset in
                let record = batch[offset]
                guard let entry = entries[record.id] else { return }
                let document = makeDocument(
                    record: record, entry: entry,
                    maximumPostingBytes: postingBudgetPerDocument,
                    gramFilter: Data()
                )
                resultLock.withLock { prepared.append((offset, record.id, document)) }
            }
            let temporaryBytes = prepared.reduce(0) { total, prepared in
                total + 512 + Self.postingBytes(document: prepared.2)
            }
            index.peakBuildResidentBytes = max(
                index.peakBuildResidentBytes,
                index.estimatedResidentBytes + temporaryBytes
            )
            for (_, id, document) in prepared.sorted(by: { $0.0 < $1.0 })
                where !document.tokens.isEmpty {
                index.upgradeDocument(id: id, document: document)
            }
            start += count
        }
        return index
    }

    mutating func upsert(record: ClipRecord, entry: ClipSearchEntry) {
        let slot = Self.slot(for: record.id)
        var segment = segments[slot] ?? Segment(slot: slot, documents: [:], postings: [:])
        if let previous = segment.documents[record.id] {
            estimatedResidentBytes = max(
                0, estimatedResidentBytes - Self.estimate(document: previous)
            )
            accountedBodyBytes = max(0, accountedBodyBytes - previous.bodyResidentBytes)
        }
        Self.remove(record.id, from: &segment)
        let document = Self.makeDocument(record: record, entry: entry)
        let filter = document.gramFilter
        let addedEstimate = Self.estimate(document: document)
        var inserted: Document?
        // The incremental slot, offset-map and id-set cost of admitting this document is
        // part of what it will occupy, so it belongs in the decision, not only in the
        // reconciliation afterwards.
        let structuralOverhead = Self.perDocumentOverheadBytes
        if estimatedResidentBytes + addedEstimate + structuralOverhead > residentLimit {
            let overflow = Document(
                recordDigest: record.digest, entryDigest: Self.digest(entry),
                tokens: [], overflowed: true,
                bodyResidentBytes: document.bodyResidentBytes,
                gramFilter: Data()
            )
            let overflowEstimate = Self.estimate(document: overflow)
            if estimatedResidentBytes + overflowEstimate + structuralOverhead <= residentLimit {
                inserted = overflow
                estimatedResidentBytes += overflowEstimate
                accountedBodyBytes += overflow.bodyResidentBytes
            }
        } else {
            var resident = document
            resident.gramFilter.removeAll(keepingCapacity: false)
            inserted = resident
            for token in document.tokens { segment.postings[token, default: []].append(record.id) }
            estimatedResidentBytes += addedEstimate
            accountedBodyBytes += document.bodyResidentBytes
        }
        if let inserted {
            segment.documents[record.id] = inserted
            documentIDs.insert(record.id)
            setGramFilter(filter, for: record.id, slot: slot)
        } else {
            documentIDs.remove(record.id)
            removeGramFilter(for: record.id, slot: slot)
        }
        if segment.documents.isEmpty { segments[slot] = nil }
        else { segments[slot] = segment }
        refreshGramOverhead()
        peakBuildResidentBytes = max(peakBuildResidentBytes, estimatedResidentBytes)
    }

    mutating func remove(_ id: UUID) {
        let slot = Self.slot(for: id)
        // Unconditional, and in this order, so "no filter slot and no cached id outlives
        // its document" is an invariant this function establishes on its own rather than
        // one that only holds on the path where a segment happened to exist.
        documentIDs.remove(id)
        releaseGramSlot(for: id, slot: slot)
        defer {
            compactGramTableIfNeeded(in: slot)
            refreshGramOverhead()
        }
        guard var segment = segments[slot] else { return }
        if let document = segment.documents[id] {
            estimatedResidentBytes = max(0, estimatedResidentBytes - Self.estimate(document: document))
            accountedBodyBytes = max(0, accountedBodyBytes - document.bodyResidentBytes)
        }
        Self.remove(id, from: &segment)
        if segment.documents.isEmpty {
            segments[slot] = nil
        } else {
            segments[slot] = segment
        }
    }

    /// Deleting a selection, a retention sweep and an application purge all hand over a
    /// whole set at once. Removing them together touches each affected segment's
    /// dictionaries once and repacks its filter table at most once.
    mutating func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for (slot, group) in Dictionary(grouping: ids, by: Self.slot(for:)) {
            // Same invariant as the single-id path, established before anything is
            // known about whether this slot has a segment at all.
            documentIDs.subtract(group)
            for id in group { releaseGramSlot(for: id, slot: slot) }
            defer { compactGramTableIfNeeded(in: slot) }
            guard var segment = segments[slot] else { continue }
            for id in group {
                if let document = segment.documents[id] {
                    estimatedResidentBytes = max(
                        0, estimatedResidentBytes - Self.estimate(document: document)
                    )
                    accountedBodyBytes = max(
                        0, accountedBodyBytes - document.bodyResidentBytes
                    )
                }
                Self.remove(id, from: &segment)
            }
            if segment.documents.isEmpty { segments[slot] = nil }
            else { segments[slot] = segment }
        }
        refreshGramOverhead()
    }

    /// "Nothing here" and "this slot is damaged" are different answers.
    ///
    /// They used to share a `nil`, and `encodedSegment(slot:)`'s `?? Segment(...)` turned
    /// the second one into an authentic, signed, *empty* segment on disk — silently
    /// deleting a populated slot's whole search index because its in-memory filter table
    /// had lost sync with its documents.
    private enum SegmentMaterialization {
        case empty
        case materialized(Segment)
        case inconsistent(reason: String)
    }

    func segment(slot: Int) -> Segment? {
        switch materializeSegment(slot: slot) {
        case .empty: return nil
        case .materialized(let segment): return segment
        case .inconsistent(let reason):
            Self.log.error(
                "search index slot \(slot, privacy: .public) is inconsistent: \(reason, privacy: .public)"
            )
            return nil
        }
    }

    private func materializeSegment(slot: Int) -> SegmentMaterialization {
        guard var segment = segments[slot] else { return .empty }
        guard let table = gramTables[slot] else { return .materialized(segment) }
        guard table.bytes.count == table.ids.count * Self.gramFilterByteCount else {
            return .inconsistent(
                reason: "packed filter bytes \(table.bytes.count) do not cover "
                    + "\(table.ids.count) slots"
            )
        }
        for (offset, entry) in table.ids.enumerated() {
            guard let id = entry else { continue }
            guard var document = segment.documents[id] else {
                return .inconsistent(reason: "filter slot \(offset) has no document")
            }
            let start = offset * Self.gramFilterByteCount
            document.gramFilter = table.bytes.subdata(
                in: start..<(start + Self.gramFilterByteCount)
            )
            segment.documents[id] = document
        }
        return .materialized(segment)
    }

    private mutating func compactFilters(in slot: Int) {
        guard var segment = segments[slot] else {
            gramTables[slot] = nil
            return
        }
        let ids = segment.documents.keys.sorted { $0.uuidString < $1.uuidString }
        var packed = Data()
        packed.reserveCapacity(ids.count * Self.gramFilterByteCount)
        for id in ids {
            guard var document = segment.documents[id],
                  document.gramFilter.count == Self.gramFilterByteCount
            else { return }
            packed.append(document.gramFilter)
            document.gramFilter.removeAll(keepingCapacity: false)
            segment.documents[id] = document
        }
        segments[slot] = segment
        gramTables[slot] = GramTable(ids: ids, bytes: packed)
    }

    private mutating func setGramFilter(_ filter: Data, for id: UUID, slot: Int) {
        guard filter.count == Self.gramFilterByteCount else { return }
        let width = Self.gramFilterByteCount
        var table = gramTables[slot] ?? GramTable(ids: [], bytes: Data())
        if let offset = table.offsets[id] {
            let start = offset * width
            table.bytes.replaceSubrange(start..<(start + width), with: filter)
        } else if let offset = table.freeSlots.popLast() {
            // Reuse a tombstone before growing: an edit-heavy history otherwise ratchets
            // the packed table upward and never gives the bytes back.
            table.ids[offset] = id
            table.offsets[id] = offset
            let start = offset * width
            table.bytes.replaceSubrange(start..<(start + width), with: filter)
        } else {
            table.offsets[id] = table.ids.count
            table.ids.append(id)
            table.bytes.append(filter)
        }
        gramTables[slot] = table
    }

    private mutating func removeGramFilter(for id: UUID, slot: Int) {
        releaseGramSlot(for: id, slot: slot)
        compactGramTableIfNeeded(in: slot)
    }

    /// Marks the slot free in O(1). The packed bytes are left in place; every reader
    /// walks `ids` and skips tombstones, so stale filter bits are never consulted.
    private mutating func releaseGramSlot(for id: UUID, slot: Int) {
        guard var table = gramTables[slot],
              let offset = table.offsets.removeValue(forKey: id) else { return }
        table.ids[offset] = nil
        table.freeSlots.append(offset)
        if table.offsets.isEmpty {
            gramTables[slot] = nil
            return
        }
        gramTables[slot] = table
    }

    /// Reconciles `gramTableOverheadBytes` with what the tables and the id set actually
    /// hold, and moves `estimatedResidentBytes` by the difference.
    ///
    /// A full recomputation rather than a delta: there are at most sixteen slots, so this
    /// is a sixteen-iteration loop over integers, and an accounting counter that can be
    /// re-derived from the structures it describes cannot drift out of sync with them.
    private mutating func refreshGramOverhead() {
        var updated = documentIDs.count * Self.documentIDBytes
        for table in gramTables.values { updated += table.overheadBytes }
        guard updated != gramTableOverheadBytes else { return }
        estimatedResidentBytes = max(
            0, estimatedResidentBytes - gramTableOverheadBytes + updated
        )
        gramTableOverheadBytes = updated
    }

    private mutating func compactGramTableIfNeeded(in slot: Int) {
        guard let table = gramTables[slot], table.shouldCompact else { return }
        let width = Self.gramFilterByteCount
        let source = table.bytes
        var packed = Data()
        packed.reserveCapacity(table.liveCount * width)
        var ids: [UUID?] = []
        ids.reserveCapacity(table.liveCount)
        var offsets: [UUID: Int] = [:]
        offsets.reserveCapacity(table.liveCount)
        for (offset, entry) in table.ids.enumerated() {
            guard let id = entry else { continue }
            let start = offset * width
            guard start + width <= source.count else { return }
            packed.append(source[start..<(start + width)])
            offsets[id] = ids.count
            ids.append(id)
        }
        var compacted = table
        compacted.ids = ids
        compacted.offsets = offsets
        compacted.freeSlots = []
        compacted.bytes = packed
        gramTables[slot] = compacted.offsets.isEmpty ? nil : compacted
    }

    func contains(record: ClipRecord, entry: ClipSearchEntry) -> Bool {
        segments[Self.slot(for: record.id)]?.contains(
            recordID: record.id, recordDigest: record.digest, entry: entry
        ) == true
    }

    mutating func replaceSegment(_ segment: Segment) throws {
        guard segment.version == Self.formatVersion else {
            throw Failure.unsupportedVersion(segment.version)
        }
        guard (0..<Self.segmentCount).contains(segment.slot) else { throw Failure.malformed }
        var estimate = 0
        for document in segment.documents.values {
            estimate += Self.estimate(document: document)
            guard estimate <= residentLimit else { throw Failure.budgetExceeded }
        }
        let previous = segments[segment.slot]
        if let previous {
            estimatedResidentBytes -= previous.documents.values.reduce(0) {
                $0 + Self.estimate(document: $1)
            }
            accountedBodyBytes -= previous.documents.values.reduce(0) {
                $0 + $1.bodyResidentBytes
            }
        }
        guard estimatedResidentBytes + estimate <= residentLimit else {
            throw Failure.budgetExceeded
        }
        segments[segment.slot] = segment
        // Both mutations happen past the last `throw`, so a rejected segment cannot
        // leave the cached id set describing documents that were never installed.
        if let previous { documentIDs.subtract(previous.documents.keys) }
        documentIDs.formUnion(segment.documents.keys)
        estimatedResidentBytes += estimate
        accountedBodyBytes += segment.documents.values.reduce(0) {
            $0 + $1.bodyResidentBytes
        }
        compactFilters(in: segment.slot)
        refreshGramOverhead()
        peakBuildResidentBytes = max(peakBuildResidentBytes, estimatedResidentBytes)
    }

    /// Throws rather than substituting an empty segment when the slot is damaged.
    ///
    /// The caller's own error path skips the write, which leaves whatever is already on
    /// disk intact. Persisting a well-formed empty segment for an occupied slot would be
    /// indistinguishable from a legitimate deletion and would survive every integrity
    /// check the restore path applies.
    func encodedSegment(slot: Int) throws -> Data {
        switch materializeSegment(slot: slot) {
        case .empty:
            return try Self.encodedSegment(
                Segment(slot: slot, documents: [:], postings: [:])
            )
        case .materialized(let segment):
            return try Self.encodedSegment(segment)
        case .inconsistent(let reason):
            Self.log.error(
                "refusing to persist slot \(slot, privacy: .public): \(reason, privacy: .public)"
            )
            throw Failure.malformed
        }
    }

    static func encodedSegment(_ segment: Segment) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(segment)
    }

    static func decodeSegment(_ data: Data, expectedSlot: Int) throws -> Segment {
        guard data.count <= 64 * 1024 * 1024 else { throw Failure.budgetExceeded }
        let segment: Segment
        do { segment = try JSONDecoder().decode(Segment.self, from: data) }
        catch { throw Failure.malformed }
        guard segment.version == formatVersion else {
            throw Failure.unsupportedVersion(segment.version)
        }
        guard segment.slot == expectedSlot else {
            throw Failure.wrongSlot(expected: expectedSlot, actual: segment.slot)
        }
        guard segment.documents.count <= 20_000,
              segment.postings.count <= 2_000_000 else { throw Failure.budgetExceeded }
        let known = Set(segment.documents.keys)
        var estimate = 0
        for (token, ids) in segment.postings {
            guard !token.isEmpty, token.count <= maximumTokenLength,
                  ids.count <= segment.documents.count,
                  Set(ids).count == ids.count,
                  ids.allSatisfy(known.contains)
            else { throw Failure.malformed }
        }
        for (id, document) in segment.documents {
            guard !document.recordDigest.isEmpty, document.entryDigest.count == 64,
                  document.tokens.count <= maximumTokensPerDocument,
                  document.bodyResidentBytes >= 0,
                  document.gramFilter.count == gramFilterByteCount,
                  document.tokens.allSatisfy({ !$0.isEmpty && $0.count <= maximumTokenLength })
            else { throw Failure.malformed }
            for token in document.tokens where segment.postings[token]?.contains(id) != true {
                throw Failure.malformed
            }
            estimate += Self.estimate(document: document)
            guard estimate <= maximumResidentBytes else { throw Failure.budgetExceeded }
        }
        return segment
    }

    func candidates(
        for term: String, fuzzy: Bool = true,
        cancellation: ClipSearchCancellationToken? = nil
    ) -> ClipSearchCandidateResult {
        let parts = Self.lexicalTokens(in: term, limit: 32).values
        // Punctuation-only terms cannot be represented in the lexical index. All ids are
        // therefore the only safe candidate set; the normal verifier remains decisive.
        guard !parts.isEmpty else {
            return ClipSearchCandidateResult(ids: documentIDs, cancelled: false)
        }
        var combined: Set<UUID>?
        for part in parts {
            if cancellation?.isCancelled == true {
                return ClipSearchCandidateResult(ids: [], cancelled: true)
            }
            var matches = Set<UUID>()
            let probe = GramProbe(term: part, fuzzy: fuzzy)
            // The fixed filter represents every token, not only the bounded posting
            // lexicon. A 5,000-document scan is ~40MiB of compact sequential reads and
            // never touches 160MiB of bodies or walks millions of token Dictionary keys.
            var visited = 0
            for slot in gramTables.keys.sorted() {
                guard let table = gramTables[slot] else { continue }
                table.bytes.withUnsafeBytes { rawBuffer in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self)
                    for (offset, entry) in table.ids.enumerated() {
                        guard let id = entry else { continue }
                        visited += 1
                        if visited.isMultiple(of: 32), cancellation?.isCancelled == true {
                            return
                        }
                        let start = offset * Self.gramFilterByteCount
                        if probe.mightMatch(bytes, startingAt: start) { matches.insert(id) }
                    }
                }
                if cancellation?.isCancelled == true {
                    return ClipSearchCandidateResult(ids: [], cancelled: true)
                }
            }
            combined = combined.map { $0.intersection(matches) } ?? matches
            if combined?.isEmpty == true { break }
        }
        return ClipSearchCandidateResult(ids: combined ?? [], cancelled: false)
    }

    private mutating func upgradeDocument(id: UUID, document: Document) {
        let slot = Self.slot(for: id)
        guard var segment = segments[slot], let previous = segment.documents[id] else { return }
        let delta = Self.estimateStructure(document: document)
            - Self.estimateStructure(document: previous)
        guard delta >= 0, estimatedResidentBytes + delta <= residentLimit else { return }
        segment.documents[id] = document
        for token in document.tokens { segment.postings[token, default: []].append(id) }
        segments[slot] = segment
        estimatedResidentBytes += delta
        peakBuildResidentBytes = max(peakBuildResidentBytes, estimatedResidentBytes)
    }

    private static func remove(_ id: UUID, from segment: inout Segment) {
        guard let previous = segment.documents.removeValue(forKey: id) else { return }
        for token in previous.tokens {
            guard var ids = segment.postings[token] else { continue }
            ids.removeAll { $0 == id }
            if ids.isEmpty { segment.postings[token] = nil }
            else { segment.postings[token] = ids }
        }
    }

    private static func tokens(
        record: ClipRecord, entry: ClipSearchEntry,
        maximumPostingBytes: Int = .max
    ) -> (values: [String], overflowed: Bool) {
        var set = Set<String>()
        var overflowed = false
        let maximumCount: Int
        if maximumPostingBytes == .max {
            maximumCount = maximumTokensPerDocument
        } else {
            let worstSinglePosting = minimumPostingBytes + (2 * maximumTokenLength)
            maximumCount = min(
                maximumTokensPerDocument, max(0, maximumPostingBytes / worstSinglePosting)
            )
        }
        for source in [record.preview, record.sourceName ?? "", entry.text, entry.pinyin, entry.initials] {
            let result = lexicalTokens(in: source, limit: maximumCount - set.count)
            set.formUnion(result.values)
            overflowed = overflowed || result.overflowed
            if set.count >= maximumCount { overflowed = true; break }
        }
        return (set.sorted(), overflowed)
    }

    private static func makeDocument(
        record: ClipRecord, entry: ClipSearchEntry, maximumPostingBytes: Int = .max,
        gramFilter: Data? = nil
    ) -> Document {
        let tokenized = tokens(
            record: record, entry: entry, maximumPostingBytes: maximumPostingBytes
        )
        return Document(
            recordDigest: record.digest, entryDigest: digest(entry),
            tokens: tokenized.values, overflowed: tokenized.overflowed,
            bodyResidentBytes: estimateBody(entry: entry),
            gramFilter: gramFilter ?? makeGramFilter(record: record, entry: entry)
        )
    }

    private static func makePackedOverflowSegment(
        slot: Int, records: [ClipRecord], entries: [UUID: ClipSearchEntry]
    ) -> (Segment, GramTable) {
        let ids = records.map(\.id)
        var packed = Data(count: records.count * gramFilterByteCount)
        var documents: [UUID: Document] = [:]
        documents.reserveCapacity(records.count)
        packed.withUnsafeMutableBytes { rawBuffer in
            let allBytes = rawBuffer.bindMemory(to: UInt8.self)
            for (offset, record) in records.enumerated() {
                guard let entry = entries[record.id] else { continue }
                let start = offset * gramFilterByteCount
                let filter = UnsafeMutableBufferPointer(
                    rebasing: allBytes[start..<(start + gramFilterByteCount)]
                )
                fillGramFilter(record: record, entry: entry, bytes: filter)
                documents[record.id] = Document(
                    recordDigest: record.digest, entryDigest: digest(entry), tokens: [],
                    overflowed: true, bodyResidentBytes: estimateBody(entry: entry),
                    gramFilter: Data()
                )
            }
        }
        return (
            Segment(slot: slot, documents: documents, postings: [:]),
            GramTable(ids: ids, bytes: packed)
        )
    }

    private static func makeGramFilter(record: ClipRecord, entry: ClipSearchEntry) -> Data {
        var filter = Data(count: gramFilterByteCount)
        filter.withUnsafeMutableBytes { rawBuffer in
            fillGramFilter(
                record: record, entry: entry,
                bytes: rawBuffer.bindMemory(to: UInt8.self)
            )
        }
        return filter
    }

    private static func fillGramFilter(
        record: ClipRecord, entry: ClipSearchEntry,
        bytes: UnsafeMutableBufferPointer<UInt8>
    ) {
        func add(_ source: String) {
            let sourceBytes: [UInt8]
            if source.utf8.allSatisfy({ $0 < 0x80 }) {
                sourceBytes = Array(source.utf8)
            } else {
                sourceBytes = Array(normalise(source).utf8)
            }
            var first: UInt8?
            var second: UInt8?
            var thirdBack: UInt8?
            var fourthBack: UInt8?
            for raw in sourceBytes {
                let byte = raw >= 65 && raw <= 90 ? raw + 32 : raw
                let lexical = (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57) || byte >= 0x80
                guard lexical else {
                    first = nil
                    second = nil
                    thirdBack = nil
                    fourthBack = nil
                    continue
                }
                if let first, let second {
                    let bit = gram3Bit(first, second, byte)
                    bytes[bit >> 3] |= UInt8(1) << UInt8(bit & 7)
                }
                if let fourthBack, let thirdBack, let first, let second {
                    let bit = gram5Bit(fourthBack, thirdBack, first, second, byte)
                    bytes[bit >> 3] |= UInt8(1) << UInt8(bit & 7)
                }
                fourthBack = thirdBack
                thirdBack = first
                first = second
                second = byte
            }
        }
        add(record.preview)
        if let source = record.sourceName { add(source) }
        add(entry.text)
        if !entry.pinyin.isEmpty { add(entry.pinyin) }
        if !entry.initials.isEmpty { add(entry.initials) }
    }

    private static func gram3Bit(_ first: UInt8, _ second: UInt8, _ third: UInt8) -> Int {
        var value = UInt64(first) << 16 | UInt64(second) << 8 | UInt64(third)
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        return Int(value & UInt64(gram3FilterByteCount * 8 - 1))
    }

    private static func gram5Bit(
        _ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8, _ fifth: UInt8
    ) -> Int {
        var value: UInt64 = 1_469_598_103_934_665_603
        value = (value ^ UInt64(first)) &* 1_099_511_628_211
        value = (value ^ UInt64(second)) &* 1_099_511_628_211
        value = (value ^ UInt64(third)) &* 1_099_511_628_211
        value = (value ^ UInt64(fourth)) &* 1_099_511_628_211
        value = (value ^ UInt64(fifth)) &* 1_099_511_628_211
        value ^= value >> 32
        value &*= 0xD6E8_FEB8_6659_FD93
        value ^= value >> 32
        let local = Int(value & UInt64(gram5FilterByteCount * 8 - 1))
        return gram3FilterByteCount * 8 + local
    }

    private static func lexicalTokens(
        in source: String, limit: Int
    ) -> (values: [String], overflowed: Bool) {
        guard limit > 0 else { return ([], !source.isEmpty) }
        var result: [String] = []
        result.reserveCapacity(min(limit, 128))
        var seen: [UInt64: [[UInt8]]] = [:]
        seen.reserveCapacity(min(limit, 128))
        var current: [UInt8] = []
        current.reserveCapacity(24)
        var overflowed = false
        var currentWasTruncated = false
        func finish() {
            guard !current.isEmpty else { return }
            if currentWasTruncated { overflowed = true }
            // Avoid constructing a Swift String for every repeated word in a 32K body.
            // The hash only picks a bucket; byte equality still resolves collisions, so
            // this is an allocation optimisation rather than a correctness shortcut.
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in current { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            if seen[hash]?.contains(current) == true {
                current.removeAll(keepingCapacity: true)
                currentWasTruncated = false
                return
            }
            if result.count < limit {
                seen[hash, default: []].append(current)
                result.append(String(decoding: current, as: UTF8.self))
            } else {
                overflowed = true
            }
            current.removeAll(keepingCapacity: true)
            currentWasTruncated = false
        }
        for byte in source.utf8 {
            if byte >= 0x80 {
                return unicodeLexicalTokens(in: source, limit: limit)
            }
            let lower = byte >= 65 && byte <= 90 ? byte + 32 : byte
            if (lower >= 97 && lower <= 122) || (lower >= 48 && lower <= 57) {
                if current.count < maximumTokenLength { current.append(lower) }
                else { currentWasTruncated = true }
            } else {
                finish()
            }
        }
        finish()
        return (result, overflowed)
    }

    private static func unicodeLexicalTokens(
        in source: String, limit: Int
    ) -> (values: [String], overflowed: Bool) {
        var result = Set<String>()
        var current = ""
        var overflowed = false
        func finish() {
            guard !current.isEmpty else { return }
            if current.count > maximumTokenLength { overflowed = true }
            let token = normalise(String(current.prefix(maximumTokenLength)))
            if result.count < limit { result.insert(token) }
            else if !result.contains(token) { overflowed = true }
            current.removeAll(keepingCapacity: true)
        }
        for character in source {
            if character.isLetter || character.isNumber { current.append(character) }
            else { finish() }
        }
        finish()
        return (Array(result), overflowed)
    }

    static func normalise(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private struct GramProbe {
        var bits3: [Int]
        var minimum3Hits: Int
        var bits5: [Int]
        var minimum5Hits: Int

        init(term: String, fuzzy: Bool) {
            let bytes = Array(term.utf8)
            if bytes.count >= 3, bytes.allSatisfy({ $0 < 0x80 }) {
                bits3 = (0...(bytes.count - 3)).map {
                    ClipSearchIndex.gram3Bit(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])
                }
            } else {
                bits3 = []
            }
            if bytes.count >= 5, bytes.allSatisfy({ $0 < 0x80 }) {
                bits5 = (0...(bytes.count - 5)).map {
                    ClipSearchIndex.gram5Bit(
                        bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3],
                        bytes[$0 + 4]
                    )
                }
            } else {
                bits5 = []
            }
            let allowed = fuzzy ? ClipSearchIndex.fuzzyAllowance(for: term) : 0
            minimum3Hits = max(0, bits3.count - 3 * allowed)
            minimum5Hits = max(0, bits5.count - 5 * allowed)
        }

        func mightMatch(_ filter: Data) -> Bool {
            guard (!bits3.isEmpty && minimum3Hits > 0)
                    || (!bits5.isEmpty && minimum5Hits > 0),
                  filter.count == ClipSearchIndex.gramFilterByteCount else { return true }
            return filter.withUnsafeBytes {
                mightMatch($0.bindMemory(to: UInt8.self), startingAt: 0)
            }
        }

        func mightMatch(
            _ filter: UnsafeBufferPointer<UInt8>, startingAt start: Int
        ) -> Bool {
            guard (!bits3.isEmpty && minimum3Hits > 0)
                    || (!bits5.isEmpty && minimum5Hits > 0),
                  start >= 0,
                  start + ClipSearchIndex.gramFilterByteCount <= filter.count
            else { return true }
            if minimum3Hits > 0,
               !hasMinimumHits(
                   bits3, minimum: minimum3Hits, in: filter, startingAt: start
               ) {
                return false
            }
            if minimum5Hits > 0,
               !hasMinimumHits(
                   bits5, minimum: minimum5Hits, in: filter, startingAt: start
               ) {
                return false
            }
            return true
        }

        private func hasMinimumHits(
            _ bits: [Int], minimum: Int, in filter: UnsafeBufferPointer<UInt8>,
            startingAt start: Int
        ) -> Bool {
            var hits = 0
            var remaining = bits.count
            for bit in bits {
                if filter[start + (bit >> 3)] & (UInt8(1) << UInt8(bit & 7)) != 0 {
                    hits += 1
                }
                remaining -= 1
                if hits + remaining < minimum { return false }
            }
            return hits >= minimum
        }
    }

    static func fuzzyAllowance(for term: String) -> Int {
        // Typos in natural-language words are useful. Fuzzing IDs, OTPs, URLs and build
        // numbers produces surprising multi-row matches and defeats exact overflow filters.
        guard term.allSatisfy(\.isLetter) else { return 0 }
        return term.count >= 8 ? 2 : (term.count >= 4 ? 1 : 0)
    }

    static func editDistance(_ left: String, _ right: String, limit: Int) -> Int {
        let a = Array(left), b = Array(right)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        var previous = Array(0...b.count)
        for (row, value) in a.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: b.count)
            var rowMinimum = current[0]
            for column in b.indices {
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + (value == b[column] ? 0 : 1)
                )
                rowMinimum = min(rowMinimum, current[column + 1])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    private static func digest(_ entry: ClipSearchEntry) -> String {
        let data = Data((entry.text + "\0" + entry.pinyin + "\0" + entry.initials).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func estimate(document: Document) -> Int {
        document.bodyResidentBytes + estimateStructure(document: document)
    }

    private static func estimateStructure(document: Document) -> Int {
        // Resident segments pack these bytes into `GramTable`; persisted/materialised
        // documents carry the same bytes individually. Charge the full fixed width in
        // both forms so compaction cannot make the accounting counter look smaller.
        512 + 64 + gramFilterByteCount + postingBytes(document: document)
    }

    private static func postingBytes(document: Document) -> Int {
        document.tokens.reduce(0) {
            $0 + minimumPostingBytes + (2 * $1.utf8.count)
        }
    }

    private static func estimateBody(entry: ClipSearchEntry) -> Int {
        384 + entry.text.utf8.count + entry.pinyin.utf8.count + entry.initials.utf8.count
    }

}

struct ClipSearchCandidateResult: Sendable {
    var ids: Set<UUID>
    var cancelled: Bool
}

enum ClipSearch {
    /// A copied file can be a whole book; indexing all of it would put the history's
    /// entire text in memory. 32KiB of UTF-8 is far past where anyone still recognises
    /// what they copied, and (unlike a character cap) bounds emoji/CJK bodies too.
    static let maxTextLength = 32 * 1024

    /// Romanising is linear in the input and only ever helps with the beginning of an
    /// entry, so it looks at a small window rather than the whole 32K.
    static let pinyinSourceLength = 2 * 1024

    // MARK: - Building

    static func makeEntry(text: String) -> ClipSearchEntry? {
        let capped: String
        if text.utf8.count <= maxTextLength {
            capped = text
        } else {
            var bytes = 0
            var end = text.startIndex
            for character in text {
                let width = character.utf8.count
                guard bytes + width <= maxTextLength else { break }
                bytes += width
                end = text.index(after: end)
            }
            capped = String(text[..<end])
        }
        guard !capped.isEmpty else { return nil }
        let romanised = romanise(String(capped.prefix(pinyinSourceLength)))
        return ClipSearchEntry(text: capped, pinyin: romanised.compact, initials: romanised.initials)
    }

    /// Runs `CFStringTransform` twice: Mandarin-Latin produces tone marks, which nobody
    /// types, so a second pass strips them back down to plain ASCII.
    private static func romanise(_ text: String) -> (compact: String, initials: String) {
        guard text.unicodeScalars.contains(where: isCJK) else { return ("", "") }

        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

        var compact = ""
        var initials = ""
        var atSyllableStart = true
        for scalar in (mutable as String).lowercased().unicodeScalars {
            guard scalar.value >= 97, scalar.value <= 122 else {
                atSyllableStart = true
                continue
            }
            if atSyllableStart {
                initials.unicodeScalars.append(scalar)
                atSyllableStart = false
            }
            compact.unicodeScalars.append(scalar)
        }
        return (compact, initials)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,  // extension A
             0x4E00...0x9FFF,  // unified
             0xF900...0xFAFF,  // compatibility
             0x20000...0x2FA1F:  // extensions B and beyond
            return true
        default:
            return false
        }
    }

    // MARK: - Query

    /// Whitespace-separated words, matched with AND. Typing more never widens the
    /// result set, which is the behaviour that makes narrowing down feel predictable.
    static func terms(from query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    }

    /// The one comparison every search path uses: case- and accent-insensitive, so
    /// "cafe" finds "Café" and a query never has to match the exact keystrokes.
    static func firstRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        // Clipboard bodies are overwhelmingly ASCII code, URLs and identifiers. ICU's
        // case+diacritic search costs several milliseconds per 32KiB false candidate.
        // Scan contiguous UTF-8 directly when both sides are ASCII, folding A-Z inline;
        // any non-ASCII byte falls through to the exact Unicode-aware implementation.
        let needleBytes = Array(needle.utf8)
        if !needleBytes.isEmpty, needleBytes.allSatisfy({ $0 < 0x80 }) {
            let foldedNeedle = needleBytes.map { byte in
                byte >= 65 && byte <= 90 ? byte + 32 : byte
            }
            var offsets: (Int, Int)?
            var fullyASCII = true
            let contiguous = haystack.utf8.withContiguousStorageIfAvailable { bytes in
                guard bytes.count >= foldedNeedle.count else {
                    fullyASCII = bytes.allSatisfy { $0 < 0x80 }
                    return
                }
                let lastStart = bytes.count - foldedNeedle.count
                for start in 0...lastStart {
                    let first = bytes[start]
                    if first >= 0x80 { fullyASCII = false; return }
                    let foldedFirst = first >= 65 && first <= 90 ? first + 32 : first
                    guard foldedFirst == foldedNeedle[0] else { continue }
                    var matched = true
                    for offset in 1..<foldedNeedle.count {
                        let value = bytes[start + offset]
                        if value >= 0x80 { fullyASCII = false; return }
                        let folded = value >= 65 && value <= 90 ? value + 32 : value
                        if folded != foldedNeedle[offset] { matched = false; break }
                    }
                    if matched {
                        offsets = (start, start + foldedNeedle.count)
                        return
                    }
                }
                // The loop only inspects candidate starts and a matching prefix. Confirm
                // the whole body is ASCII before treating a miss as authoritative.
                fullyASCII = bytes.allSatisfy { $0 < 0x80 }
            } != nil
            if contiguous, let offsets {
                let lower = haystack.utf8.index(
                    haystack.utf8.startIndex, offsetBy: offsets.0
                )
                let upper = haystack.utf8.index(
                    haystack.utf8.startIndex, offsetBy: offsets.1
                )
                return lower..<upper
            }
            if contiguous, fullyASCII { return nil }
        }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        firstRange(of: needle, in: haystack) != nil
    }

    /// Pinyin only makes sense for a query that could *be* pinyin. Without this, "png"
    /// would run a pinyin comparison against every CJK entry in the history.
    private static func isLatinOnly(_ term: String) -> Bool {
        guard !term.isEmpty else { return false }
        return term.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 }
    }

    static func matches(record: ClipRecord, entry: ClipSearchEntry?, terms: [String]) -> Bool {
        for term in terms {
            if contains(record.preview, term) { continue }
            if let source = record.sourceName, contains(source, term) { continue }
            if let entry {
                if contains(entry.text, term) { continue }
                if isLatinOnly(term) {
                    if !entry.pinyin.isEmpty, entry.pinyin.contains(term) { continue }
                    if !entry.initials.isEmpty, entry.initials.contains(term) { continue }
                }
            }
            return false
        }
        return true
    }

    // MARK: - Running

    static func run(_ request: ClipSearchRequest, in snapshot: ClipSearchSnapshot) -> ClipSearchOutcome {
        if let query = request.query {
            return runAdvanced(query, request: request, snapshot: snapshot)
        }
        var result = snapshot.records
        if request.pinnedOnly { result = result.filter(\.pinned) }
        if let kind = request.kind { result = result.filter { $0.kind == kind } }

        guard !request.terms.isEmpty else {
            return ClipSearchOutcome(records: result, terms: [], contexts: [:])
        }

        var contexts: [UUID: String] = [:]
        result = result.filter { record in
            let entry = snapshot.index[record.id]
            guard matches(record: record, entry: entry, terms: request.terms) else { return false }
            // A hit buried past the preview is invisible in the row — the label would
            // show text with nothing highlighted in it and look like a false positive.
            // Carrying a snippet lets the row explain why it is in the list.
            // The hit's position is found once and handed to `context`, rather than
            // scanning the same 32K of text a second time to answer where it was.
            if let entry,
               let hidden = request.terms.first(where: { !contains(record.preview, $0) }),
               let hit = firstRange(of: hidden, in: entry.text),
               let snippet = context(in: entry.text, around: hit) {
                contexts[record.id] = snippet
            }
            return true
        }
        return ClipSearchOutcome(records: result, terms: request.terms, contexts: contexts)
    }

    private struct RankedRecord {
        var record: ClipRecord
        var score: Int
        var originalIndex: Int
    }

    private struct Relevance {
        var score: Int
        var explanations: [ClipSearchMatchExplanation]
    }

    /// One query term plus its case/diacritic-folded form.
    ///
    /// Folding is a full Unicode transform and an allocation. The term does not change
    /// between candidates, so a search over 5,000 rows used to run the identical
    /// `normalise` 5,000 times per term for no new information.
    private struct PreparedTerm {
        let term: ClipQueryTerm
        let normalized: String
    }

    /// Per-record folded text, computed at most once per record per search and reused by
    /// every term. The entry body is the expensive one — up to 32KiB through ICU — and
    /// is only produced when a fuzzy comparison actually needs it.
    private struct NormalizedRecord {
        let record: ClipRecord
        let entry: ClipSearchEntry?
        private var previewCache: String?
        private var sourceCache: String??
        private var entryTextCache: String?

        init(record: ClipRecord, entry: ClipSearchEntry?) {
            self.record = record
            self.entry = entry
        }

        mutating func preview() -> String {
            if let previewCache { return previewCache }
            let value = ClipSearchIndex.normalise(record.preview)
            previewCache = value
            return value
        }

        mutating func sourceName() -> String? {
            if let sourceCache { return sourceCache }
            let value = record.sourceName.map(ClipSearchIndex.normalise)
            sourceCache = .some(value)
            return value
        }

        mutating func entryText() -> String? {
            guard let entry else { return nil }
            if let entryTextCache { return entryTextCache }
            let value = ClipSearchIndex.normalise(entry.text)
            entryTextCache = value
            return value
        }
    }

    private static func runAdvanced(
        _ query: ClipQuery, request: ClipSearchRequest, snapshot: ClipSearchSnapshot
    ) -> ClipSearchOutcome {
        if request.cancellation?.isCancelled == true {
            return ClipSearchOutcome(records: [], terms: query.highlightTerms, contexts: [:], cancelled: true)
        }

        var candidateIDs: Set<UUID>?
        if let inverted = snapshot.invertedIndex {
            // Built at most once, and only for a query that actually consults the index.
            // This used to materialise a full copy of every record id and subtract from
            // it on every keystroke, including queries with no positive text term at all.
            var unrepresented: Set<UUID>?
            for term in query.textTerms where !term.negated {
                let result = inverted.candidates(
                    for: term.value, cancellation: request.cancellation
                )
                if result.cancelled {
                    return ClipSearchOutcome(
                        records: [], terms: query.highlightTerms, contexts: [:], cancelled: true
                    )
                }
                var candidates = result.ids
                // A pathological corpus can consume the body budget before even the
                // minimal overflow marker fits. Those ids remain verifier fallbacks.
                let missing: Set<UUID>
                if let unrepresented {
                    missing = unrepresented
                } else {
                    let known = inverted.documentIDs
                    var collected = Set<UUID>()
                    for record in snapshot.records where !known.contains(record.id) {
                        collected.insert(record.id)
                    }
                    unrepresented = collected
                    missing = collected
                }
                candidates.formUnion(missing)
                candidateIDs = candidateIDs.map { $0.intersection(candidates) } ?? candidates
                if candidateIDs?.isEmpty == true { break }
            }
        }

        // Folded once for the whole search rather than once per candidate per term.
        let preparedTerms = query.textTerms.map {
            PreparedTerm(term: $0, normalized: ClipSearchIndex.normalise($0.value))
        }

        var ranked: [RankedRecord] = []
        ranked.reserveCapacity(candidateIDs?.count ?? snapshot.records.count)
        var contexts: [UUID: String] = [:]
        var explanations: [UUID: [ClipSearchMatchExplanation]] = [:]

        for (originalIndex, record) in snapshot.records.enumerated() {
            if originalIndex.isMultiple(of: 64), request.cancellation?.isCancelled == true {
                return ClipSearchOutcome(
                    records: [], terms: query.highlightTerms, contexts: [:], cancelled: true
                )
            }
            if let candidateIDs, !candidateIDs.contains(record.id) { continue }
            guard metadataMatches(record, query: query, queuedIDs: snapshot.queuedIDs) else { continue }
            let entry = snapshot.index[record.id]
            guard let relevance = relevance(
                record: record, entry: entry, query: query, textTerms: preparedTerms
            ) else { continue }
            ranked.append(RankedRecord(
                record: record, score: relevance.score, originalIndex: originalIndex
            ))
            if !relevance.explanations.isEmpty { explanations[record.id] = relevance.explanations }

            if let entry,
               let hidden = query.highlightTerms.first(where: { !contains(record.preview, $0) }),
               let hit = firstRange(of: hidden, in: entry.text),
               let snippet = context(in: entry.text, around: hit) {
                contexts[record.id] = snippet
            }
        }

        if query.hasPositiveTextTerm || !query.appTerms.isEmpty {
            ranked.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.record.createdAt != $1.record.createdAt {
                    return $0.record.createdAt > $1.record.createdAt
                }
                return $0.originalIndex < $1.originalIndex
            }
        }
        return ClipSearchOutcome(
            records: ranked.map(\.record), terms: query.highlightTerms,
            contexts: contexts, matchExplanations: explanations
        )
    }

    private static func metadataMatches(
        _ record: ClipRecord, query: ClipQuery, queuedIDs: Set<UUID>
    ) -> Bool {
        if !query.kinds.isEmpty, !query.kinds.contains(record.kind) { return false }
        if query.excludedKinds.contains(record.kind) { return false }
        if let before = query.before, record.createdAt >= before { return false }
        if let after = query.after, record.createdAt < after { return false }
        if let pinned = query.pinned, record.pinned != pinned { return false }
        if let queued = query.queued, queuedIDs.contains(record.id) != queued { return false }

        let source = record.sourceName ?? ""
        for term in query.appTerms {
            let hit = contains(source, term.value)
            if hit == term.negated { return false }
        }
        return true
    }

    private static func relevance(
        record: ClipRecord, entry: ClipSearchEntry?, query: ClipQuery,
        textTerms: [PreparedTerm]
    ) -> Relevance? {
        var score = 0
        var explanations: [ClipSearchMatchExplanation] = []
        var normalized = NormalizedRecord(record: record, entry: entry)
        for prepared in textTerms {
            let term = prepared.term
            let match = matchQuality(
                normalized: &normalized, term: term.value,
                normalizedTerm: prepared.normalized
            )
            if term.negated {
                if match != nil { return nil }
            } else {
                guard var match else { return nil }
                if term.phrase { match.explanation.kind = .phrase }
                score += match.score + (term.phrase ? 25 : 0)
                explanations.append(match.explanation)
            }
        }
        for term in query.appTerms where !term.negated {
            if let source = record.sourceName,
               let range = firstRange(of: term.value, in: source) {
                score += 35
                explanations.append(ClipSearchMatchExplanation(
                    term: term.value, kind: .source,
                    utf16Range: NSRange(range, in: source), matchedText: source
                ))
            }
        }
        if record.pinned { score += 2 }
        return Relevance(score: score, explanations: explanations)
    }

    private static func matchQuality(
        normalized: inout NormalizedRecord, term: String, normalizedTerm: String
    ) -> (score: Int, explanation: ClipSearchMatchExplanation)? {
        let record = normalized.record
        let entry = normalized.entry
        let preview = normalized.preview()
        func literal(
            score: Int, kind: ClipSearchMatchKind, source: String
        ) -> (Int, ClipSearchMatchExplanation)? {
            guard let range = firstRange(of: term, in: source) else { return nil }
            return (score, ClipSearchMatchExplanation(
                term: term, kind: kind, utf16Range: NSRange(range, in: source),
                matchedText: String(source[range])
            ))
        }
        if preview == normalizedTerm { return literal(score: 160, kind: .exact, source: record.preview) }
        if preview.hasPrefix(normalizedTerm) { return literal(score: 135, kind: .prefix, source: record.preview) }
        if preview.contains(normalizedTerm) { return literal(score: 120, kind: .substring, source: record.preview) }
        if let source = normalized.sourceName(),
           source.contains(normalizedTerm), let original = record.sourceName {
            return literal(score: 100, kind: .source, source: original)
        }
        if let entry {
            // The verifier used to normalise the entire 32KiB body and then ask
            // `literal` to scan it a second time. One case/diacritic-insensitive range
            // is the exact same predicate and preserves the original UTF-16 range.
            if let range = firstRange(of: term, in: entry.text) {
                return (90, ClipSearchMatchExplanation(
                    term: term, kind: .substring, utf16Range: NSRange(range, in: entry.text),
                    matchedText: String(entry.text[range])
                ))
            }
            if !entry.pinyin.isEmpty, entry.pinyin.contains(normalizedTerm) {
                return (82, ClipSearchMatchExplanation(
                    term: term, kind: .pinyin, utf16Range: nil,
                    matchedText: entry.pinyin
                ))
            }
            if !entry.initials.isEmpty, entry.initials.contains(normalizedTerm) {
                return (78, ClipSearchMatchExplanation(
                    term: term, kind: .initials, utf16Range: nil,
                    matchedText: entry.initials
                ))
            }
            let queryTokens = lexicalTerms(normalizedTerm)
            // Multi-token values (URLs, identifiers and quoted literals) have meaningful
            // separator/adjacency semantics. Treating any constituent as fuzzy turns
            // `unique_219_349` into a hit for every document containing `unique`.
            guard queryTokens.count == 1 else { return nil }
            let query = queryTokens[0]
            let allowed = ClipSearchIndex.fuzzyAllowance(for: query)
            // Identifiers, URLs, numeric values and short terms are literal-only. Do not
            // allocate thousands of source tokens when fuzzy matching is impossible.
            guard allowed > 0, let normalizedText = normalized.entryText() else { return nil }
            let sourceTokens = lexicalTerms(normalizedText)
            if let matched = sourceTokens.first(where: {
                abs($0.count - query.count) <= allowed
                    && ClipSearchIndex.editDistance($0, query, limit: allowed) <= allowed
            }) {
                return (55, ClipSearchMatchExplanation(
                    term: term, kind: .fuzzy, utf16Range: nil, matchedText: matched
                ))
            }
        }
        return nil
    }

    private static func lexicalTerms(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber { current.append(character) }
            else if !current.isEmpty { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Highlighting

    /// Every occurrence of any term, merged and in order, so a caller can walk the
    /// string once. Capped per term because highlighting the thousandth "the" in a
    /// pasted chapter helps nobody and costs a run of attributes each.
    static func ranges(in string: String, terms: [String], limit: Int = 80) -> [Range<String.Index>] {
        guard !terms.isEmpty, !string.isEmpty else { return [] }

        var found: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var cursor = string.startIndex
            var count = 0
            while count < limit, cursor < string.endIndex,
                  let hit = string.range(
                      of: term,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: cursor..<string.endIndex
                  ) {
                found.append(hit)
                count += 1
                cursor = hit.upperBound > hit.lowerBound
                    ? hit.upperBound
                    : string.index(after: hit.lowerBound)
            }
        }
        guard !found.isEmpty else { return [] }

        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [found[0]]
        for range in found.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A one-line window around the first hit, with ellipses where text was cut off.
    static func context(in text: String, terms: [String], radius: Int = 20) -> String? {
        var earliest: Range<String.Index>?
        for term in terms where !term.isEmpty {
            guard let hit = firstRange(of: term, in: text) else { continue }
            if earliest == nil || hit.lowerBound < earliest!.lowerBound { earliest = hit }
        }
        guard let hit = earliest else { return nil }
        return context(in: text, around: hit, radius: radius)
    }

    /// The same window, for a caller that already knows where the hit is — the search
    /// loop does, and finding it again is a second pass over the whole entry.
    static func context(
        in text: String, around hit: Range<String.Index>, radius: Int = 20
    ) -> String? {
        let start = text.index(hit.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: radius, limitedBy: text.endIndex)
            ?? text.endIndex
        let slice = collapsingWhitespace(text[start..<end])
        guard !slice.isEmpty else { return nil }

        return (start > text.startIndex ? "…" : "") + slice + (end < text.endIndex ? "…" : "")
    }

    /// Runs of whitespace squeezed to one space, and the ends trimmed.
    ///
    /// Hand-written rather than `replacingOccurrences(of: "\\s+", options:
    /// .regularExpression)`: that call compiles the pattern afresh every time, and this
    /// runs once per matching row of a search — a hundred regular expressions built and
    /// thrown away per keystroke, for a substitution a single walk does.
    private static func collapsingWhitespace(_ slice: Substring) -> String {
        var out = ""
        out.reserveCapacity(slice.count)
        var pendingSpace = false
        for character in slice {
            guard !character.isWhitespace else {
                // Held rather than written, so a run at the very end leaves nothing
                // behind — which is what the trim used to do.
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out
    }
}
