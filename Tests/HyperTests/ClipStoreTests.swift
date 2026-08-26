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

    func testFlushingBeforeTheIndexLoadsLeavesTheHistoryOnDisk() throws {
        try seedIndex([record("older", age: 60), record("newer", age: 30)])

        // Quitting in the first moments after launch. `records` is still empty, and an
        // empty index.json would turn every payload on disk into an orphan for the next
        // start's `reconcileOrphans` to delete.
        let store = ClipStore(root: root)
        XCTAssertFalse(store.isLoaded)
        store.flushNow()
        store.waitForPendingWrites()

        XCTAssertEqual(try decodeIndex().map(\.preview), ["older", "newer"])
    }

    func testALaunchWindowRecopyKeepsTheDiskRecordsIdentity() throws {
        let onDisk = record("copied twice", age: 3600, pinned: true)
        let other = record("something else", age: 7200)
        try seedIndex([onDisk, other])

        let store = ClipStore(root: root)
        XCTAssertFalse(store.isLoaded)
        // Copied again before the index arrived, so it is recorded under a fresh id:
        // there is nothing in memory yet for the digest to collapse onto.
        let captured = store.insert(textInsertion("copied twice"))
        XCTAssertNotEqual(captured.id, onDisk.id)

        let loaded = expectation(description: "loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(store.records.count, 2, "the duplicate does not become a second row")
        XCTAssertNil(store.record(id: captured.id), "the launch-window capture is discarded")
        let survivor = try XCTUnwrap(store.record(id: onDisk.id))
        XCTAssertTrue(survivor.pinned, "the pin on disk survives the merge")
        XCTAssertGreaterThan(survivor.createdAt, onDisk.createdAt, "a re-copy still bumps it")
        XCTAssertEqual(store.records.map(\.id), [onDisk.id, other.id])

        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().map(\.id), [onDisk.id, other.id])
        XCTAssertFalse(
            exists("data/\(captured.id.uuidString).plist"),
            "the discarded capture's sidecar files go with it"
        )
        XCTAssertFalse(exists("search/\(captured.id.uuidString).txt"))
        XCTAssertEqual(
            store.search("copied", kind: nil, pinnedOnly: false).map(\.id), [onDisk.id],
            "the indexed body moves to the id that kept the row"
        )
    }

    func testANewCaptureDuringTheLaunchWindowJoinsTheLoadedHistory() throws {
        let seeded = record("already here", age: 3600)
        try seedIndex([seeded])

        let store = ClipStore(root: root)
        let captured = store.insert(textInsertion("brand new"))

        let loaded = expectation(description: "loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(store.records.map(\.id), [captured.id, seeded.id], "newest first")
        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().map(\.id), [captured.id, seeded.id])
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

        store.deleteUndoable([inserted.id])
        // Deletion is undoable for a few seconds, so the files only go once the batch is
        // committed — which is what this test is about the far side of.
        store.commitPendingDeletion()
        store.waitForPendingWrites()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(id: inserted.id))
        XCTAssertFalse(exists("data/\(inserted.id.uuidString).plist"))
        XCTAssertFalse(exists("search/\(inserted.id.uuidString).txt"))
        XCTAssertNil(store.payload(for: inserted.id))
    }

    // MARK: - Undoable deletion

    func testPanelDeleteKeepsTheFilesUntilTheBatchIsCommitted() throws {
        let store = makeStore()
        let doomed = store.insert(textInsertion("a needle to delete"))
        let kept = store.insert(textInsertion("stays put"))
        store.waitForPendingWrites()

        let removed = store.deleteUndoable([doomed.id])
        store.waitForPendingWrites()

        XCTAssertEqual(removed.map(\.id), [doomed.id])
        XCTAssertEqual(store.records.map(\.id), [kept.id], "the row is gone from the history")
        XCTAssertTrue(
            store.search("needle", kind: nil, pinnedOnly: false).isEmpty,
            "and stops matching searches while it waits"
        )
        XCTAssertTrue(
            exists("data/\(doomed.id.uuidString).plist"),
            "but its payload has to survive, or the undo would have nothing to restore"
        )

        // Written out immediately: the undo buffer is memory only, so a crash inside the
        // window must not leave the deleted row back in index.json.
        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().map(\.id), [kept.id])

        store.commitPendingDeletion()
        store.waitForPendingWrites()
        XCTAssertFalse(exists("data/\(doomed.id.uuidString).plist"))
        XCTAssertFalse(exists("search/\(doomed.id.uuidString).txt"))
    }

    func testUndoPutsADeletedBatchBackInItsPlace() throws {
        let store = makeStore()
        let pinnedItem = store.insert(textInsertion("pinned and deleted"))
        store.togglePin(pinnedItem.id)
        let plain = store.insert(textInsertion("a needle, plain"))
        let bystander = store.insert(textInsertion("never touched"))

        store.deleteUndoable([pinnedItem.id, plain.id])
        XCTAssertEqual(store.records.map(\.id), [bystander.id])

        let restored = store.undoLastDelete()
        XCTAssertEqual(Set(restored.map(\.id)), [pinnedItem.id, plain.id])
        XCTAssertEqual(
            store.records.map(\.id), [pinnedItem.id, bystander.id, plain.id],
            "the pin floats back to the top and the rest lands newest-first"
        )
        XCTAssertTrue(store.records[0].pinned, "the pinned flag comes back with the row")
        XCTAssertEqual(
            store.search("needle", kind: nil, pinnedOnly: false).map(\.id), [plain.id],
            "and the full-text entry is rebuilt, not just the index row"
        )

        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().count, 3)
        XCTAssertTrue(exists("data/\(plain.id.uuidString).plist"))

        XCTAssertTrue(store.undoLastDelete().isEmpty, "one batch, undone once")
    }

    /// A restored pin brings its old rank back with it, and `togglePin` hands out numbers
    /// counted over the rows that are *present* — so a pin made inside the undo window is
    /// given a place the buffer is still holding. Two pins with one rank would be ordered
    /// by the clock instead, which has nothing to do with the order the user arranged.
    func testUndoRenumbersTheBandRatherThanRestoringAClashingRank() throws {
        let store = makeStore()
        let first = store.insert(textInsertion("pinned first"))
        let second = store.insert(textInsertion("pinned second"))
        store.togglePin(first.id)
        store.togglePin(second.id)
        let plain = store.insert(textInsertion("never pinned"))
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, nil])

        store.deleteUndoable([first.id, second.id])

        // With the band empty the next pin is handed rank 0 — the number the deleted row
        // is still holding in the buffer.
        let newcomer = store.insert(textInsertion("pinned during the undo window"))
        store.togglePin(newcomer.id)
        XCTAssertEqual(store.record(id: newcomer.id)?.pinnedRank, 0)

        XCTAssertEqual(store.undoLastDelete().map(\.id), [first.id, second.id])

        XCTAssertEqual(
            store.records.filter(\.pinned).map(\.pinnedRank), [0, 1, 2],
            "the band is renumbered 0..n, so no two pins claim one place"
        )
        XCTAssertEqual(
            store.records.map(\.id), [first.id, second.id, newcomer.id, plain.id],
            "the restored pins keep their order and the newcomer stays at the end of the band"
        )

        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(
            try decodeIndex().map(\.pinnedRank), [0, 1, 2, nil],
            "and the settled order is what is written down"
        )
    }

    func testASecondDeleteMakesTheFirstOnePermanent() {
        let store = makeStore()
        let first = store.insert(textInsertion("first to go"))
        let second = store.insert(textInsertion("second to go"))
        store.waitForPendingWrites()

        store.deleteUndoable([first.id])
        store.deleteUndoable([second.id])
        store.waitForPendingWrites()

        XCTAssertFalse(
            exists("data/\(first.id.uuidString).plist"),
            "only one batch is held, so the older one is committed on the way past"
        )
        XCTAssertTrue(exists("data/\(second.id.uuidString).plist"))

        XCTAssertEqual(store.undoLastDelete().map(\.id), [second.id])
        XCTAssertEqual(store.records.map(\.id), [second.id])
    }

    func testClearingTheHistoryCannotBeUndoneInto() {
        let store = makeStore()
        let doomed = store.insert(textInsertion("deleted first"))
        store.deleteUndoable([doomed.id])

        // "清空历史" has to mean it — a pending undo putting rows back afterwards would be
        // the one outcome nobody could have asked for.
        store.clearAll()
        store.waitForPendingWrites()

        XCTAssertTrue(store.undoLastDelete().isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(exists("data/\(doomed.id.uuidString).plist"))
    }

    func testDeletingSomethingAbsentIsHarmless() {
        let store = makeStore()
        store.insert(textInsertion("stay"))
        XCTAssertTrue(store.deleteUndoable([UUID()]).isEmpty)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(
            store.undoLastDelete().isEmpty,
            "and it leaves no empty batch behind for ⌘Z to find"
        )
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

    /// The 收藏 band is ordered by the ranks `togglePin` hands out, not by the clock — so a
    /// newer pin joins at the *end* of the band rather than jumping to the front of it,
    /// and unpinning takes the place in the band away with the pin.
    func testPinningRanksTheBandInTheOrderRowsWerePinned() {
        let store = makeStore()
        let first = store.insert(textInsertion("first"))
        let second = store.insert(textInsertion("second"))
        let third = store.insert(textInsertion("third"))

        // Deliberately against the clock: the oldest row is pinned first.
        store.togglePin(first.id)
        store.togglePin(third.id)

        XCTAssertEqual(
            store.records.map(\.id), [first.id, third.id, second.id],
            "pins keep the order they were pinned in, newest history last"
        )
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, nil])

        store.togglePin(first.id)
        XCTAssertNil(
            store.record(id: first.id)?.pinnedRank, "unpinning gives up the place in the band"
        )
        XCTAssertEqual(store.records.map(\.id), [third.id, second.id, first.id])

        // Re-pinned, it is an arrival: behind the rank already handed out, not in front.
        store.togglePin(first.id)
        XCTAssertEqual(store.records.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(store.records.map(\.pinnedRank), [1, 2, nil])
    }

    /// An index written before ranks existed has pins and no order for them. They are
    /// given one on the way in — the order they were already being shown in — and it is
    /// written back to disk, so it is decided once rather than on every launch.
    func testOlderPinnedEntriesAreGivenRanksOnLoad() throws {
        let older = record("pinned, older", age: 5_000, pinned: true)
        let newer = record("pinned, newer", age: 100, pinned: true)
        let plain = record("not pinned", age: 50)
        try seedIndex([newer, older, plain])

        let store = makeStore()
        XCTAssertEqual(
            store.records.map(\.preview), ["pinned, newer", "pinned, older", "not pinned"],
            "the band is left exactly as it was being shown"
        )
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, nil])

        store.flushNow()
        XCTAssertEqual(
            try decodeIndex().map(\.pinnedRank), [0, 1, nil],
            "the ranks are written down rather than re-derived on every launch"
        )
    }

    func testMovePinnedRewritesTheBandAndLeavesTheRestAlone() {
        let store = makeStore()
        let plain = store.insert(textInsertion("not pinned"))
        let a = store.insert(textInsertion("a"))
        let b = store.insert(textInsertion("b"))
        let c = store.insert(textInsertion("c"))
        for id in [a.id, b.id, c.id] { store.togglePin(id) }
        XCTAssertEqual(store.records.map(\.id), [a.id, b.id, c.id, plain.id])

        // The last of the band dragged to the front of it.
        store.movePinned(from: 2, to: 0)
        XCTAssertEqual(store.records.map(\.id), [c.id, a.id, b.id, plain.id])
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, 2, nil])

        // And back into the middle.
        store.movePinned(from: 0, to: 1)
        XCTAssertEqual(store.records.map(\.id), [a.id, c.id, b.id, plain.id])
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, 2, nil])

        // Indices outside the band, or a move to where the row already is, do nothing —
        // the drag calls this on every row the pointer crosses, including its own.
        store.movePinned(from: 1, to: 1)
        store.movePinned(from: 0, to: 3)
        store.movePinned(from: -1, to: 0)
        XCTAssertEqual(store.records.map(\.id), [a.id, c.id, b.id, plain.id])
        XCTAssertNil(store.record(id: plain.id)?.pinnedRank, "an unpinned row is never ranked")
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

    func testSweepReportsWhatItEvicted() throws {
        let doomed = record("old", age: 40 * 86400)
        try seedIndex([record("fresh", age: 60), doomed])

        let store = makeStore()
        store.retentionDays = 30
        store.maxItems = 1000
        var evicted: [UUID] = []
        // Retention is the one deletion the store performs unprompted, so it is the one
        // the paste queue cannot learn about any other way.
        store.onEvicted = { evicted.append(contentsOf: $0) }
        store.sweep()

        XCTAssertEqual(evicted, [doomed.id])
        XCTAssertEqual(store.records.map(\.preview), ["fresh"])
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

    /// 设置 › 清理孤儿文件 can be pressed inside the ten seconds a deletion stays undoable, and
    /// the batch's files are deliberately still on disk with no record naming them. Taken
    /// for garbage they would leave ⌘Z restoring an empty shell of a row.
    func testReconcileOrphansSparesAPendingDeletionsFiles() throws {
        let store = makeStore()
        let doomed = store.insert(textInsertion("a needle, deleted but undoable"))
        let live = store.insert(textInsertion("never touched"))
        store.waitForPendingWrites()

        store.deleteUndoable([doomed.id])
        XCTAssertEqual(store.pendingDeletionIDs, [doomed.id])

        store.reconcileOrphans()
        store.waitForPendingWrites()

        XCTAssertTrue(
            exists("data/\(doomed.id.uuidString).plist"),
            "the payload the undo will need is not an orphan while the batch is held"
        )
        XCTAssertTrue(exists("search/\(doomed.id.uuidString).txt"))
        XCTAssertTrue(exists("data/\(live.id.uuidString).plist"))

        // And the row that comes back is whole, not a shell.
        XCTAssertEqual(store.undoLastDelete().map(\.id), [doomed.id])
        XCTAssertNotNil(store.payload(for: doomed.id), "it is pastable again")
        XCTAssertEqual(
            store.search("needle", kind: nil, pinnedOnly: false).map(\.id), [doomed.id],
            "and findable again"
        )

        // Once the batch is committed the same files are ordinary orphans.
        store.deleteUndoable([doomed.id])
        store.commitPendingDeletion()
        XCTAssertTrue(store.pendingDeletionIDs.isEmpty)
        store.reconcileOrphans()
        store.waitForPendingWrites()
        XCTAssertFalse(exists("data/\(doomed.id.uuidString).plist"))
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

    func testContentTagIsDerivedOnCaptureAndReReadOnEdit() throws {
        let store = makeStore()
        let json = store.insert(textInsertion(#"{"ok": true}"#))
        XCTAssertEqual(json.contentTag, .json)

        // The tag has to be cleared as well as set, or an edited row would keep
        // describing what it used to hold.
        let edited = try XCTUnwrap(store.updateText(id: json.id, newText: "就是一句普通的话"))
        XCTAssertNil(edited.contentTag)
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
