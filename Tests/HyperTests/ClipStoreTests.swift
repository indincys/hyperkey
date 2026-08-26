import AppKit
import XCTest

@testable import Hyper

/// The store is main-thread-only state with background disk I/O behind it, so every test
/// here runs on the main thread and waits on the store's own seams — `whenLoaded` for the
/// asynchronous index read, `waitForPendingWrites` for the file queue, `flushNow` for the
/// debounced index write.
final class ClipStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// A store whose index has finished loading. Nothing may read `records` before this.
    private func makeStore() -> ClipStore {
        let store = ClipStore(root: root)
        let loaded = expectation(description: "index loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        return store
    }

    private func textInsertion(_ text: String, source: String? = "Tests") -> ClipStore.Insertion {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        return ClipStore.Insertion(
            payload: payload,
            kind: ClipCapture.textKind(for: text),
            oversized: false,
            byteSize: ClipPayloadCoder.byteSize(payload),
            sourceBundleID: nil,
            sourceName: source
        )
    }

    private func record(
        _ text: String, age: TimeInterval, pinned: Bool = false, id: UUID = UUID()
    ) -> ClipRecord {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        return ClipRecord(
            id: id,
            createdAt: Date().addingTimeInterval(-age),
            kind: .text,
            preview: text,
            digest: ClipPayloadCoder.digest(payload),
            byteSize: ClipPayloadCoder.byteSize(payload),
            sourceBundleID: nil,
            sourceName: "Tests",
            pinned: pinned
        )
    }

    /// Seeds `index.json` before the store is created, which is the only way to get
    /// records with a chosen age: `insert` always stamps them with now.
    private func seedIndex(_ records: [ClipRecord]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: root.appendingPathComponent("index.json"))
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private func decodeIndex() throws -> [ClipRecord] {
        let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ClipRecord].self, from: data)
    }

    // MARK: - Insert

    func testInsertWritesTheRecordItsPayloadAndItsSearchText() throws {
        let store = makeStore()
        let inserted = store.insert(textInsertion("hello from the tests"))
        store.flushNow()
        store.waitForPendingWrites()

        XCTAssertEqual(store.records.map(\.id), [inserted.id])
        XCTAssertEqual(inserted.preview, "hello from the tests")
        XCTAssertEqual(inserted.sourceName, "Tests")

        XCTAssertTrue(exists("data/\(inserted.id.uuidString).plist"))
        XCTAssertTrue(exists("search/\(inserted.id.uuidString).txt"))
        XCTAssertFalse(exists("thumbs/\(inserted.id.uuidString).png"), "text has no thumbnail")

        let onDisk = try decodeIndex()
        XCTAssertEqual(onDisk.map(\.id), [inserted.id])

        let payload = try XCTUnwrap(store.payload(for: inserted.id))
        XCTAssertEqual(ClipCapture.plainText(from: payload), "hello from the tests")

        let searchText = try String(
            contentsOf: root.appendingPathComponent("search/\(inserted.id.uuidString).txt"),
            encoding: .utf8
        )
        XCTAssertEqual(searchText, "hello from the tests")
    }

    func testOversizedEntryKeepsItsMetadataButWritesNoPayload() {
        let store = makeStore()
        var insertion = textInsertion("far too big")
        insertion.oversized = true
        let inserted = store.insert(insertion)
        store.waitForPendingWrites()

        XCTAssertTrue(store.records[0].oversized)
        XCTAssertFalse(exists("data/\(inserted.id.uuidString).plist"))
        // Still searchable: knowing what you copied is why the row is kept at all.
        XCTAssertTrue(exists("search/\(inserted.id.uuidString).txt"))
    }

    func testRecopyBumpsToTheTopInsteadOfDuplicating() {
        let store = makeStore()
        let first = store.insert(textInsertion("first"))
        let second = store.insert(textInsertion("second"))
        XCTAssertEqual(store.records.map(\.id), [second.id, first.id])

        let again = store.insert(textInsertion("first"))
        XCTAssertEqual(again.id, first.id, "the same content keeps its identity")
        XCTAssertEqual(store.records.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.records.count, 2)
    }

    func testRecopyPreservesPinnedStateAndSource() {
        let store = makeStore()
        let pinnedItem = store.insert(textInsertion("keep me", source: "Safari"))
        store.togglePin(pinnedItem.id)
        XCTAssertTrue(store.records[0].pinned)

        store.insert(textInsertion("something else"))
        let again = store.insert(textInsertion("keep me", source: "Ghostty"))

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(again.id, pinnedItem.id)
        XCTAssertTrue(again.pinned, "a re-copy must not silently unpin")
        XCTAssertEqual(again.sourceName, "Safari", "the original source survives the bump")
        XCTAssertEqual(store.records[0].id, pinnedItem.id, "pinned entries float to the top")
    }

    func testGenerationAdvancesOnEveryChange() {
        let store = makeStore()
        let before = store.generation
        store.insert(textInsertion("something"))
        XCTAssertGreaterThan(store.generation, before)
    }

    // MARK: - Loading

    func testRecordsAreNotVisibleUntilTheIndexLoads() throws {
        try seedIndex([record("older", age: 60), record("newer", age: 30)])

        let store = ClipStore(root: root)
        XCTAssertFalse(store.isLoaded, "the read is asynchronous by design")
        XCTAssertTrue(store.records.isEmpty)

        let loaded = expectation(description: "loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.records.map(\.preview), ["older", "newer"])

        // Already loaded, so a later waiter runs straight away.
        var ranImmediately = false
        store.whenLoaded { ranImmediately = true }
        XCTAssertTrue(ranImmediately)
    }

    func testSearchIndexIsBackfilledFromPayloadsInTheBackground() throws {
        // A record written before the sidecar files existed: payload on disk, no
        // search/<uuid>.txt. Its full text is only findable once the scan has run.
        let seeded = record("preview only", age: 10)
        try seedIndex([seeded])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("data"), withIntermediateDirectories: true
        )
        let payload: ClipPayload = [["public.utf8-plain-text": Data("preview only, plus a buried needle".utf8)]]
        try XCTUnwrap(ClipPayloadCoder.encode(payload)).write(
            to: root.appendingPathComponent("data/\(seeded.id.uuidString).plist")
        )

        let store = ClipStore(root: root)
        let indexed = expectation(description: "search index ready")
        store.onSearchIndexLoaded = { indexed.fulfill() }
        wait(for: [indexed], timeout: 5)

        XCTAssertEqual(store.search("needle", kind: nil, pinnedOnly: false).map(\.id), [seeded.id])
        store.waitForPendingWrites()
        XCTAssertTrue(
            exists("search/\(seeded.id.uuidString).txt"),
            "the backfilled text is written out so the next launch need not redo it"
        )
    }

    func testCorruptIndexIsMovedAsideAndPayloadsSurvive() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("data"), withIntermediateDirectories: true
        )
        let orphanPayload = root.appendingPathComponent("data/\(UUID().uuidString).plist")
        try Data("payload".utf8).write(to: orphanPayload)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: root.appendingPathComponent("index.json"))

        let store = makeStore()
        XCTAssertTrue(store.records.isEmpty)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(
            names.contains { $0.hasPrefix("index.json.corrupt-") },
            "the unreadable index is kept aside rather than deleted; got \(names)"
        )
        XCTAssertFalse(names.contains("index.json"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphanPayload.path),
            "nothing is silently destroyed"
        )
    }

    // MARK: - Delete and clear

    func testDeleteRemovesTheRecordAndEveryFileBehindIt() {
        let store = makeStore()
        let inserted = store.insert(textInsertion("delete me"))
        store.waitForPendingWrites()
        XCTAssertTrue(exists("data/\(inserted.id.uuidString).plist"))

        store.delete(inserted.id)
        store.waitForPendingWrites()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(id: inserted.id))
        XCTAssertFalse(exists("data/\(inserted.id.uuidString).plist"))
        XCTAssertFalse(exists("search/\(inserted.id.uuidString).txt"))
        XCTAssertNil(store.payload(for: inserted.id))
    }

    func testDeletingSomethingAbsentIsHarmless() {
        let store = makeStore()
        store.insert(textInsertion("stay"))
        store.delete(UUID())
        XCTAssertEqual(store.records.count, 1)
    }

    func testClearUnpinnedKeepsWhatWasDeliberatelyKept() {
        let store = makeStore()
        let kept = store.insert(textInsertion("kept"))
        store.togglePin(kept.id)
        let dropped = store.insert(textInsertion("dropped"))
        store.waitForPendingWrites()

        store.clearUnpinned()
        store.waitForPendingWrites()

        XCTAssertEqual(store.records.map(\.id), [kept.id])
        XCTAssertTrue(exists("data/\(kept.id.uuidString).plist"))
        XCTAssertFalse(exists("data/\(dropped.id.uuidString).plist"))
    }

    func testClearAllTakesPinnedEntriesToo() {
        let store = makeStore()
        let pinnedItem = store.insert(textInsertion("pinned"))
        store.togglePin(pinnedItem.id)
        let other = store.insert(textInsertion("other"))
        store.waitForPendingWrites()

        store.clearAll()
        store.waitForPendingWrites()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(exists("data/\(pinnedItem.id.uuidString).plist"))
        XCTAssertFalse(exists("data/\(other.id.uuidString).plist"))
    }

    func testTogglePinMovesTheRowAndBackAgain() {
        let store = makeStore()
        let first = store.insert(textInsertion("first"))
        let second = store.insert(textInsertion("second"))
        XCTAssertEqual(store.records.map(\.id), [second.id, first.id])

        store.togglePin(first.id)
        XCTAssertEqual(store.records.map(\.id), [first.id, second.id])
        store.togglePin(first.id)
        XCTAssertEqual(store.records.map(\.id), [second.id, first.id])
    }

    // MARK: - Retention

    func testSweepEvictsByAgeAndExemptsPinned() throws {
        let old = record("old", age: 40 * 86400)
        let oldPinned = record("old but pinned", age: 40 * 86400, pinned: true)
        let fresh = record("fresh", age: 60)
        try seedIndex([oldPinned, fresh, old])

        let store = makeStore()
        store.retentionDays = 30
        store.maxItems = 1000
        store.sweep()

        XCTAssertEqual(Set(store.records.map(\.preview)), ["old but pinned", "fresh"])
    }

    func testSweepEvictsTheOldestOverTheCountCap() throws {
        let pinnedOld = record("pinned", age: 500, pinned: true)
        let seeded = (0..<4).map { record("entry \($0)", age: TimeInterval(400 - $0 * 10)) }
        // Newest-first, pinned at the top, which is the order the store keeps on disk.
        try seedIndex([pinnedOld] + seeded.reversed())

        let store = makeStore()
        store.retentionDays = 3650
        store.maxItems = 2
        store.sweep()

        XCTAssertEqual(store.records.count, 3, "two unpinned survivors plus the exempt pin")
        XCTAssertEqual(
            store.records.map(\.preview), ["pinned", "entry 3", "entry 2"],
            "the oldest unpinned entries go first"
        )
    }

    func testSweepDoesNothingWhenNothingIsOverTheLimits() throws {
        try seedIndex([record("a", age: 10), record("b", age: 20)])
        let store = makeStore()
        store.retentionDays = 30
        store.maxItems = 1000
        let before = store.generation
        store.sweep()
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.generation, before, "a no-op sweep must not schedule a write")
    }

    func testReconcileOrphansRemovesFilesWithNoRecord() throws {
        let store = makeStore()
        let live = store.insert(textInsertion("live"))
        store.waitForPendingWrites()

        let orphan = UUID()
        for (dir, ext) in [("data", "plist"), ("thumbs", "png"), ("search", "txt")] {
            try Data("stray".utf8).write(
                to: root.appendingPathComponent("\(dir)/\(orphan.uuidString).\(ext)")
            )
        }

        store.reconcileOrphans()
        store.waitForPendingWrites()

        XCTAssertFalse(exists("data/\(orphan.uuidString).plist"))
        XCTAssertFalse(exists("thumbs/\(orphan.uuidString).png"))
        XCTAssertFalse(exists("search/\(orphan.uuidString).txt"))
        XCTAssertTrue(exists("data/\(live.id.uuidString).plist"), "live payloads are untouched")
        XCTAssertTrue(exists("search/\(live.id.uuidString).txt"))
    }

    // MARK: - Editing

    func testUpdateTextRefreshesEverythingDerivedFromThePayload() throws {
        let store = makeStore()
        let original = store.insert(textInsertion("some ordinary prose"))
        store.waitForPendingWrites()
        XCTAssertEqual(original.kind, .text)

        let edited = try XCTUnwrap(store.updateText(id: original.id, newText: "https://example.com/edited"))
        store.waitForPendingWrites()

        XCTAssertEqual(edited.id, original.id, "an edit is a correction, not a new capture")
        XCTAssertEqual(edited.kind, .url, "prose edited into a link starts filtering as a link")
        XCTAssertEqual(edited.preview, "https://example.com/edited")
        XCTAssertNotEqual(edited.digest, original.digest)
        XCTAssertEqual(store.records.map(\.id), [original.id], "the row does not jump to the top")

        let payload = try XCTUnwrap(store.payload(for: original.id))
        XCTAssertEqual(ClipCapture.plainText(from: payload), "https://example.com/edited")

        XCTAssertEqual(store.search("edited", kind: nil, pinnedOnly: false).map(\.id), [original.id])
        XCTAssertTrue(store.search("ordinary", kind: nil, pinnedOnly: false).isEmpty)
    }

    func testEditedDigestStopsTheOldTextFromReviningTheRow() throws {
        let store = makeStore()
        let original = store.insert(textInsertion("before the edit"))
        store.updateText(id: original.id, newText: "after the edit")

        // Copying the pre-edit text again must record a new entry rather than quietly
        // collapsing onto — and restoring — the row that was corrected.
        let recopied = store.insert(textInsertion("before the edit"))
        XCTAssertNotEqual(recopied.id, original.id)
        XCTAssertEqual(store.records.count, 2)
    }

    func testUpdateTextClearsTheOversizedFlag() {
        let store = makeStore()
        var insertion = textInsertion("too big to keep")
        insertion.oversized = true
        let original = store.insert(insertion)

        let edited = store.updateText(id: original.id, newText: "small now")
        XCTAssertEqual(edited?.oversized, false, "an edited entry is pastable again by definition")
    }

    func testUpdateTextOnAnUnknownIDDoesNothing() {
        let store = makeStore()
        XCTAssertNil(store.updateText(id: UUID(), newText: "nowhere"))
    }

    // MARK: - Search through the store

    func testSearchFiltersByTermKindAndPin() {
        let store = makeStore()
        let text = store.insert(textInsertion("a needle in the text"))
        let link = store.insert(textInsertion("https://example.com/needle"))
        store.togglePin(link.id)

        XCTAssertEqual(
            Set(store.search("needle", kind: nil, pinnedOnly: false).map(\.id)), [text.id, link.id]
        )
        XCTAssertEqual(store.search("needle", kind: .url, pinnedOnly: false).map(\.id), [link.id])
        XCTAssertEqual(store.search("needle", kind: nil, pinnedOnly: true).map(\.id), [link.id])
        XCTAssertTrue(store.search("haystack", kind: nil, pinnedOnly: false).isEmpty)
    }

    func testSearchSnapshotCarriesBothHalves() {
        let store = makeStore()
        let inserted = store.insert(textInsertion("indexed body"))
        let snapshot = store.searchSnapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [inserted.id])
        XCTAssertEqual(snapshot.index[inserted.id]?.text, "indexed body")
    }
}
