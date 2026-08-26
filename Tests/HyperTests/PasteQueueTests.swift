import XCTest

@testable import Hyper

/// The queue is small but it is the only piece of state a user can build up by hand and
/// lose to a restart, so ordering and the disk round-trip both matter.
final class PasteQueueTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeURL = root.appendingPathComponent("queue.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEnqueueMovesARepeatToTheEndRatherThanDuplicating() {
        let queue = PasteQueue(storeURL: storeURL)
        let (a, b, c) = (UUID(), UUID(), UUID())

        queue.enqueue(contentsOf: [a, b, c])
        XCTAssertEqual(queue.ids, [a, b, c])
        XCTAssertEqual(queue.count, 3)
        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(queue.position, 1)

        queue.enqueue(a)
        XCTAssertEqual(queue.ids, [b, c, a], "a re-collected entry should move, not duplicate")
        queue.flushNow()
    }

    func testDequeueDispensesInCollectionOrder() {
        let queue = PasteQueue(storeURL: storeURL)
        let ids = [UUID(), UUID(), UUID()]
        queue.enqueue(contentsOf: ids)

        XCTAssertEqual(queue.peek(), ids[0])
        XCTAssertEqual(queue.dequeue(), ids[0])
        XCTAssertEqual(queue.dequeue(), ids[1])
        XCTAssertEqual(queue.dequeue(), ids[2])
        XCTAssertNil(queue.dequeue())
        XCTAssertNil(queue.peek())
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.position, 0, "an empty queue has no next position")
        queue.flushNow()
    }

    func testRemoveAndClear() {
        let queue = PasteQueue(storeURL: storeURL)
        let (a, b) = (UUID(), UUID())
        queue.enqueue(contentsOf: [a, b])

        queue.remove(UUID())
        XCTAssertEqual(queue.ids, [a, b], "removing something absent must not disturb the queue")
        queue.remove(a)
        XCTAssertEqual(queue.ids, [b])
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
        queue.flushNow()
    }

    func testPruneDropsEntriesWhoseRecordsAreGone() {
        let queue = PasteQueue(storeURL: storeURL)
        let (a, b, c) = (UUID(), UUID(), UUID())
        queue.enqueue(contentsOf: [a, b, c])

        queue.prune(against: [a, c])
        XCTAssertEqual(queue.ids, [a, c], "surviving entries keep their order")
        queue.flushNow()
    }

    func testPersistsAcrossInstances() throws {
        let queue = PasteQueue(storeURL: storeURL)
        let ids = [UUID(), UUID()]
        queue.enqueue(contentsOf: ids)
        queue.flushNow()

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        let restored = PasteQueue(storeURL: storeURL)
        XCTAssertTrue(restored.isEmpty, "nothing is read until restore() is called")
        restored.restore()
        XCTAssertEqual(restored.ids, ids)

        // A second restore must not re-read and double the queue.
        restored.restore()
        XCTAssertEqual(restored.ids, ids)
    }

    func testWriteCreatesItsOwnDirectory() throws {
        // The store normally makes this directory; the queue must not depend on that.
        let nested = root.appendingPathComponent("does/not/exist/queue.json")
        let queue = PasteQueue(storeURL: nested)
        let id = UUID()
        queue.enqueue(id)
        queue.flushNow()

        let restored = PasteQueue(storeURL: nested)
        restored.restore()
        XCTAssertEqual(restored.ids, [id])
    }

    func testCorruptFileFallsBackToAnEmptyQueue() throws {
        try Data("not json at all".utf8).write(to: storeURL)

        let queue = PasteQueue(storeURL: storeURL)
        queue.restore()
        XCTAssertTrue(queue.isEmpty)

        // And the queue stays usable: the next change simply overwrites the bad file.
        let id = UUID()
        queue.enqueue(id)
        queue.flushNow()

        let reread = PasteQueue(storeURL: storeURL)
        reread.restore()
        XCTAssertEqual(reread.ids, [id])
    }

    func testMissingFileIsNotAnError() {
        let queue = PasteQueue(storeURL: storeURL)
        queue.restore()
        XCTAssertTrue(queue.isEmpty)
    }
}
