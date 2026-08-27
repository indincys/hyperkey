import XCTest

@testable import Hyper

/// The queue is small but it is the only piece of state a user can build up by hand and
/// lose to a restart, so ordering and the disk round-trip both matter.
///
/// Every queue here is restored before it is used, exactly as the app does at startup:
/// an unrestored queue deliberately writes nothing, so that quitting with the clipboard
/// feature switched off cannot overwrite the file with an empty array.
final class PasteQueueTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!

    /// A queue that has read whatever is on disk and is therefore allowed to write.
    private func makeQueue(at url: URL? = nil) -> PasteQueue {
        let queue = PasteQueue(storeURL: url ?? storeURL)
        queue.restore()
        return queue
    }

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
        let queue = makeQueue()
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
        let queue = makeQueue()
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

    func testPreparedDequeueDoesNotMutateUntilCommit() {
        let queue = makeQueue()
        let ids = [UUID(), UUID()]
        queue.enqueue(contentsOf: ids)

        let ticket = queue.prepareDequeue()

        XCTAssertNotNil(ticket)
        XCTAssertEqual(queue.ids, ids, "prepare is a reservation, not a dequeue")
        XCTAssertNil(queue.prepareDequeue(), "only one attempt may reserve the head")
        XCTAssertEqual(ticket.map(queue.commitDequeue), .committed(ids[0]))
        XCTAssertEqual(queue.ids, [ids[1]])
        queue.flushNow()
    }

    func testSuccessfulCommitIsDurableBeforeItReturns() {
        let queue = makeQueue()
        let ids = [UUID(), UUID()]
        queue.enqueue(contentsOf: ids)
        let ticket = queue.prepareDequeue()

        XCTAssertEqual(ticket.map(queue.commitDequeue), .committed(ids[0]))

        let relaunched = PasteQueue(storeURL: storeURL)
        relaunched.restore()
        XCTAssertEqual(relaunched.ids, [ids[1]])
    }

    func testFlushPendingWritesTimesOutWithoutWaitingForBlockedIO() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let barrierLock = NSLock()
        var shouldBlock = true
        let queue = PasteQueue(
            storeURL: storeURL,
            persistenceBarrier: {
                barrierLock.lock()
                let block = shouldBlock
                shouldBlock = false
                barrierLock.unlock()
                guard block else { return }
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        )
        queue.restore()
        queue.enqueue(UUID())
        let started = ProcessInfo.processInfo.systemUptime

        let result = queue.flushPendingWrites(timeout: 0.02)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertEqual(result, .timedOut(timeout: 0.02))
        XCTAssertLessThan(elapsed, 0.15)
        XCTAssertEqual(entered.wait(timeout: .now() + 0.1), .success)
        release.signal()
        XCTAssertEqual(queue.flushPendingWrites(timeout: 1), .drained)
    }

    func testTimedOutFlushEpochCannotOverwriteNewerQueueState() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let barrierLock = NSLock()
        var shouldBlock = true
        let queue = PasteQueue(
            storeURL: storeURL,
            persistenceBarrier: {
                barrierLock.lock()
                let block = shouldBlock
                shouldBlock = false
                barrierLock.unlock()
                guard block else { return }
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        )
        queue.restore()
        let stale = UUID()
        let latest = UUID()
        queue.enqueue(stale)

        XCTAssertEqual(queue.flushPendingWrites(timeout: 0.02), .timedOut(timeout: 0.02))
        XCTAssertEqual(entered.wait(timeout: .now() + 0.1), .success)
        queue.enqueue(latest)
        release.signal()
        XCTAssertEqual(queue.flushPendingWrites(timeout: 1), .drained)

        let relaunched = PasteQueue(storeURL: storeURL)
        relaunched.restore()
        XCTAssertEqual(relaunched.ids, [stale, latest])
    }

    func testEpochChangeAfterPrecheckPreventsStaleCanonicalReplace() throws {
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let newEntered = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        let barrierLock = NSLock()
        var barrierCall = 0
        let queue = PasteQueue(
            storeURL: storeURL,
            preCommitBarrier: {
                barrierLock.lock()
                barrierCall += 1
                let call = barrierCall
                barrierLock.unlock()
                if call == 2 {
                    oldEntered.signal()
                    _ = releaseOld.wait(timeout: .now() + 2)
                } else if call == 3 {
                    newEntered.signal()
                    _ = releaseNew.wait(timeout: .now() + 2)
                }
            }
        )
        queue.restore()
        let baseline = UUID()
        let stale = UUID()
        let latest = UUID()
        queue.enqueue(baseline)
        XCTAssertEqual(queue.flushPendingWrites(timeout: 1), .drained)
        queue.enqueue(stale)

        XCTAssertEqual(queue.flushPendingWrites(timeout: 0.02), .timedOut(timeout: 0.02))
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 0.1), .success)
        queue.enqueue(latest)
        releaseOld.signal()
        XCTAssertEqual(
            newEntered.wait(timeout: .now() + 1), .success,
            "the newer writer is now staged but deliberately not committed"
        )

        let canonicalWhileNewWriteIsPaused = try JSONDecoder().decode(
            [UUID].self, from: Data(contentsOf: storeURL)
        )
        XCTAssertEqual(
            canonicalWhileNewWriteIsPaused, [baseline],
            "the timed-out writer crossed its optimistic check but must not publish after a newer epoch exists"
        )

        releaseNew.signal()
        XCTAssertEqual(queue.flushPendingWrites(timeout: 1), .drained)
        let relaunched = PasteQueue(storeURL: storeURL)
        relaunched.restore()
        XCTAssertEqual(relaunched.ids, [baseline, stale, latest])
    }

    func testCommitReportsStructuredInvalidationWhenHeadMovesDuringActivation() throws {
        let queue = makeQueue()
        let ids = [UUID(), UUID()]
        queue.enqueue(contentsOf: ids)
        let ticket = try XCTUnwrap(queue.prepareDequeue())

        queue.moveDown(ids[0])
        let result = queue.commitDequeue(ticket)

        XCTAssertEqual(
            result,
            .failed(.invalidated(expectedID: ids[0], currentHead: ids[1]))
        )
        XCTAssertEqual(queue.ids, [ids[1], ids[0]])
    }

    func testCommitPersistenceFailureRetainsThePreparedItemAndReportsFailure() throws {
        let directoryAsFile = root.appendingPathComponent("queue-target", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryAsFile, withIntermediateDirectories: true)
        let queue = makeQueue(at: directoryAsFile)
        let id = UUID()
        queue.enqueue(id)
        let ticket = try XCTUnwrap(queue.prepareDequeue())

        XCTAssertEqual(queue.commitDequeue(ticket), .failed(.persistenceFailed(id: id)))
        XCTAssertEqual(queue.ids, [id])
        XCTAssertNotNil(queue.prepareDequeue(), "a persistence failure must release the reservation for retry")
    }

    func testRollbackLeavesPreparedEntryAvailableForRetry() {
        let queue = makeQueue()
        let id = UUID()
        queue.enqueue(id)
        let first = queue.prepareDequeue()

        if let first { queue.rollbackDequeue(first) }

        XCTAssertEqual(queue.ids, [id])
        let retry = queue.prepareDequeue()
        XCTAssertNotNil(retry)
        XCTAssertEqual(retry.map(queue.commitDequeue), .committed(id))
        XCTAssertTrue(queue.isEmpty)
        queue.flushNow()
    }

    func testRemoveAndClear() {
        let queue = makeQueue()
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
        let queue = makeQueue()
        let (a, b, c) = (UUID(), UUID(), UUID())
        queue.enqueue(contentsOf: [a, b, c])

        queue.prune(against: [a, c])
        XCTAssertEqual(queue.ids, [a, c], "surviving entries keep their order")
        queue.flushNow()
    }

    func testPersistsAcrossInstances() throws {
        let queue = makeQueue()
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
        let queue = makeQueue(at: nested)
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

    func testAnUnrestoredQueueNeverOverwritesTheFile() throws {
        let collected = [UUID(), UUID()]
        try JSONEncoder().encode(collected).write(to: storeURL)

        // What quitting does with the clipboard feature switched off: the queue is never
        // restored, so `applicationWillTerminate` reaches `flushNow` with an empty array
        // that came from nowhere. Writing it would destroy the last session's queue.
        let queue = PasteQueue(storeURL: storeURL)
        queue.flushNow()

        let reread = PasteQueue(storeURL: storeURL)
        reread.restore()
        XCTAssertEqual(reread.ids, collected, "an unrestored queue must save nothing")
    }

    func testMissingFileIsNotAnError() {
        let queue = PasteQueue(storeURL: storeURL)
        queue.restore()
        XCTAssertTrue(queue.isEmpty)
    }
}
