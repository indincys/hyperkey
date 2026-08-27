import AppKit
import XCTest

@testable import Hyper

final class ClipboardManagerPasteTests: XCTestCase {
    private var root: URL!
    private var store: ClipStore!
    private var queue: PasteQueue!
    private var pasteboard: NSPasteboard!
    private var accessibility: Permissions.AccessibilityStatus!
    private var activation: Paster.ActivationResult!
    private var eventResult: Result<Paster.EventDelivery, Paster.EventFailure>!
    private var eventAttempts = 0
    private var scheduledRestores: [DispatchWorkItem] = []
    private var scheduledRestoreDelays: [TimeInterval] = []
    private var deferredActivation: ((Paster.ActivationResult) -> Void)?
    private var shouldDeferActivation = false

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-manager-paste-tests-\(UUID().uuidString)", isDirectory: true)
        store = ClipStore(root: root)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        queue = PasteQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.restore()
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        accessibility = .granted
        activation = .ready
        eventResult = .success(Paster.EventDelivery(eventCount: 2))
        eventAttempts = 0
        scheduledRestores = []
        scheduledRestoreDelays = []
        deferredActivation = nil
        shouldDeferActivation = false
    }

    override func tearDownWithError() throws {
        // No work item or deferred activation may outlive the fixture whose pasteboard,
        // permission and result seams it closes over.
        for work in scheduledRestores { work.cancel() }
        scheduledRestores.removeAll()
        scheduledRestoreDelays.removeAll()
        deferredActivation = nil
        shouldDeferActivation = false
        store.waitForPendingWrites()
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: root)
        root = nil
        store = nil
        queue = nil
        pasteboard = nil
    }

    private func makeManager(restoreAfterPaste: Bool = false) -> ClipboardManager {
        var settings = ClipboardSettings()
        settings.restoreAfterPaste = restoreAfterPaste
        let environment = ClipboardManager.PasteEnvironment(
            pasteboard: pasteboard,
            accessibilityStatus: { [weak self] in self?.accessibility ?? .denied },
            activate: { [weak self] _, completion in
                guard let self else {
                    completion(.targetUnavailable)
                    return
                }
                if shouldDeferActivation {
                    deferredActivation = completion
                } else {
                    completion(activation ?? .targetUnavailable)
                }
            },
            sendPaste: { [weak self] in
                guard let self else { return .failure(.eventSourceUnavailable) }
                eventAttempts += 1
                return eventResult ?? .failure(.eventSourceUnavailable)
            },
            scheduleRestore: { [weak self] delay, work in
                guard let self else {
                    work.cancel()
                    return
                }
                scheduledRestoreDelays.append(delay)
                scheduledRestores.append(work)
            },
            afterHyperRelease: { body in body() }
        )
        return ClipboardManager(
            store: store, queue: queue, settings: settings, pasteEnvironment: environment
        )
    }

    private func insert(_ text: String) -> ClipRecord {
        let payload: ClipPayload = [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]
        let record = store.insert(
            ClipStore.Insertion(
                payload: payload, kind: .text, oversized: false,
                byteSize: ClipPayloadCoder.byteSize(payload),
                sourceBundleID: nil, sourceName: "Tests"
            )
        )
        store.waitForPendingWrites()
        return record
    }

    func testBatchCopyPreflightsEveryItemAndDoesNotSilentlyCopyOnlySurvivors() throws {
        let first = insert("first")
        let missing = insert("missing")
        try FileManager.default.removeItem(at: store.payloadLocation(for: missing.id))
        let manager = makeManager()
        let before = pasteboard.changeCount

        let result = manager.copyMerged([first, missing])

        XCTAssertEqual(result.failure, .preflightFailed)
        XCTAssertEqual(
            result.items,
            [
                ClipboardItemResult(id: first.id, state: .ready),
                ClipboardItemResult(id: missing.id, state: .failed(.missingPayload)),
            ]
        )
        XCTAssertTrue(result.shouldKeepPanelOpen)
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testPermissionDenialRetainsQueueAndGrantCanRetryWithoutRestart() {
        let record = insert("queued")
        queue.enqueue(record.id)
        accessibility = .denied
        let manager = makeManager()
        var completion: ClipboardOperationResult?

        let dispatch = manager.pasteNext { completion = $0 }

        guard case .rejected(let result) = dispatch else {
            return XCTFail("permission failure should reject synchronously")
        }
        XCTAssertEqual(result.failure, .accessibilityPermissionDenied)
        XCTAssertTrue(result.shouldKeepPanelOpen)
        XCTAssertEqual(completion, result)
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertEqual(eventAttempts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        accessibility = .granted
        var retry: ClipboardOperationResult?
        _ = manager.pasteNext { retry = $0 }
        XCTAssertTrue(retry?.succeeded == true)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(eventAttempts, 1)
    }

    func testMissingPayloadDoesNotCommitQueuedItem() throws {
        let record = insert("queued")
        queue.enqueue(record.id)
        try FileManager.default.removeItem(at: store.payloadLocation(for: record.id))
        let manager = makeManager()

        let dispatch = manager.pasteNext()

        guard case .rejected(let result) = dispatch else {
            return XCTFail("missing payload should reject synchronously")
        }
        XCTAssertEqual(result.failure, .preflightFailed)
        XCTAssertEqual(result.items, [ClipboardItemResult(id: record.id, state: .failed(.missingPayload))])
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertEqual(eventAttempts, 0)
    }

    func testEventDeliveryFailureRollsBackPreparedQueueDequeue() {
        let record = insert("queued")
        queue.enqueue(record.id)
        eventResult = .failure(.eventPostingFailed(keyDown: true))
        let manager = makeManager()
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }

        XCTAssertEqual(completion?.failure, .eventDelivery(.eventPostingFailed(keyDown: true)))
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertEqual(eventAttempts, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testTargetActivationFailureRollsBackPreparedQueueDequeue() {
        let record = insert("queued")
        queue.enqueue(record.id)
        activation = .targetUnavailable
        let manager = makeManager()
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }

        XCTAssertEqual(completion?.failure, .targetUnavailable)
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertEqual(eventAttempts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAccessibilityRevokedDuringActivationDoesNotSendOrConsumeAndRollsBack() throws {
        let record = insert("queued")
        queue.enqueue(record.id)
        shouldDeferActivation = true
        let manager = makeManager()
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }
        XCTAssertEqual(pasteboard.string(forType: .string), "queued")
        accessibility = .denied
        try XCTUnwrap(deferredActivation)(.ready)

        XCTAssertEqual(completion?.failure, .accessibilityPermissionDenied)
        XCTAssertEqual(eventAttempts, 0)
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testQueueEditDuringActivationCannotReportSuccessfulConsumption() throws {
        let first = insert("first")
        let second = insert("second")
        queue.enqueue(contentsOf: [first.id, second.id])
        shouldDeferActivation = true
        let manager = makeManager()
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }
        queue.moveDown(first.id)
        try XCTUnwrap(deferredActivation)(.ready)

        XCTAssertEqual(
            completion?.failure,
            .eventDelivery(
                .queueCommit(.invalidated(expectedID: first.id, currentHead: second.id))
            )
        )
        XCTAssertEqual(queue.ids, [second.id, first.id])
        XCTAssertEqual(eventAttempts, 1)
    }

    func testFailedPasteClearsStaleRestoreSnapshotBeforeTheNextPaste() {
        let first = insert("first")
        let failed = insert("failed")
        let third = insert("third")
        let manager = makeManager(restoreAfterPaste: true)

        _ = manager.paste(records: [first], merged: false, plainTextOnly: false, activating: nil)
        XCTAssertEqual(scheduledRestores.count, 1)

        eventResult = .failure(.eventPostingFailed(keyDown: true))
        _ = manager.paste(records: [failed], merged: false, plainTextOnly: false, activating: nil)
        XCTAssertTrue(scheduledRestores[0].isCancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), "first")

        eventResult = .success(Paster.EventDelivery(eventCount: 2))
        _ = manager.paste(records: [third], merged: false, plainTextOnly: false, activating: nil)
        XCTAssertEqual(scheduledRestores.count, 2)
        scheduledRestores[1].perform()
        XCTAssertEqual(
            pasteboard.string(forType: .string), "first",
            "the failed transaction must not carry the older original snapshot forward"
        )
    }

    func testFailureRollbackCASPreservesAUserCopyMadeDuringActivation() throws {
        let record = insert("paste me")
        shouldDeferActivation = true
        let manager = makeManager()
        var completion: ClipboardOperationResult?

        _ = manager.paste(
            records: [record], merged: false, plainTextOnly: false, activating: nil
        ) { completion = $0 }
        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)
        activation = .targetUnavailable
        try XCTUnwrap(deferredActivation)(activation)

        XCTAssertEqual(completion?.failure, .targetUnavailable)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
        guard case .attempted(.skippedPasteboardChanged) = completion?.restore else {
            return XCTFail("rollback must expose the CAS skip")
        }
    }

    func testIncompatibleMergedBatchIsAFullPreflightFailure() {
        let first = insert("first")
        let imagePayload: ClipPayload = [[
            NSPasteboard.PasteboardType.tiff.rawValue: Data([0, 1, 2])
        ]]
        let image = store.insert(
            ClipStore.Insertion(
                payload: imagePayload, kind: .image, oversized: false,
                byteSize: ClipPayloadCoder.byteSize(imagePayload),
                sourceBundleID: nil, sourceName: "Tests"
            )
        )
        store.waitForPendingWrites()
        let manager = makeManager()
        let before = pasteboard.changeCount

        let result = manager.copyMerged([first, image])

        XCTAssertEqual(result.failure, .preflightFailed)
        XCTAssertEqual(
            result.items,
            [
                ClipboardItemResult(id: first.id, state: .ready),
                ClipboardItemResult(id: image.id, state: .failedPreflight(.incompatiblePayload)),
            ]
        )
        XCTAssertTrue(result.shouldKeepPanelOpen)
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSkipInvalidBatchProcessesCompatibleItemsAndReportsEveryItem() {
        let first = insert("first")
        let imagePayload: ClipPayload = [[
            NSPasteboard.PasteboardType.tiff.rawValue: Data([0, 1, 2])
        ]]
        let image = store.insert(
            ClipStore.Insertion(
                payload: imagePayload, kind: .image, oversized: false,
                byteSize: ClipPayloadCoder.byteSize(imagePayload),
                sourceBundleID: nil, sourceName: "Tests"
            )
        )
        store.waitForPendingWrites()
        let manager = makeManager()

        let result = manager.copyMerged([first, image], batchPolicy: .skipInvalid)

        XCTAssertNil(result.failure)
        XCTAssertEqual(
            result.items,
            [
                ClipboardItemResult(id: first.id, state: .completed),
                ClipboardItemResult(id: image.id, state: .failedPreflight(.incompatiblePayload)),
            ]
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "first")
    }

    func testRestoreSchedulingUsesAdaptivePayloadCost() {
        let small = insert("small")
        let manager = makeManager(restoreAfterPaste: true)

        _ = manager.paste(records: [small], merged: false, plainTextOnly: false, activating: nil)

        XCTAssertEqual(scheduledRestoreDelays.count, 1)
        XCTAssertEqual(
            scheduledRestoreDelays[0],
            Paster.restoreDelay(for: [store.payload(for: small.id)!], targetActivationRequired: false)
        )
    }

    func testQueueCommitsExactlyOnceAfterSuccessfulEventDelivery() {
        let first = insert("first")
        let second = insert("second")
        queue.enqueue(contentsOf: [first.id, second.id])
        let manager = makeManager()
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }

        XCTAssertTrue(completion?.succeeded == true)
        XCTAssertEqual(queue.ids, [second.id])
        XCTAssertEqual(eventAttempts, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "first")
    }

    func testConsecutivePastesCancelOlderRestoreAndRestoreOriginalSnapshot() {
        let first = insert("first")
        let second = insert("second")
        let manager = makeManager(restoreAfterPaste: true)

        _ = manager.paste(
            records: [first], merged: false, plainTextOnly: false, activating: nil
        )
        _ = manager.paste(
            records: [second], merged: false, plainTextOnly: false, activating: nil
        )

        XCTAssertEqual(scheduledRestores.count, 2)
        XCTAssertTrue(scheduledRestores[0].isCancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        scheduledRestores[0].perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        scheduledRestores[1].perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testPendingRestoreDoesNotOverwriteCopyMadeByUser() {
        let record = insert("paste me")
        let manager = makeManager(restoreAfterPaste: true)

        _ = manager.paste(
            records: [record], merged: false, plainTextOnly: false, activating: nil
        )
        XCTAssertEqual(scheduledRestores.count, 1)
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)

        scheduledRestores[0].perform()

        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testCancellingFixtureWorkLetsManagersDeallocateBeforeCallbacksFire() throws {
        let record = insert("fixture lifetime")
        var restoringManager: ClipboardManager? = makeManager(restoreAfterPaste: true)
        weak let weakRestoringManager = restoringManager
        _ = restoringManager?.paste(
            records: [record], merged: false, plainTextOnly: false, activating: nil
        )
        let restore = try XCTUnwrap(scheduledRestores.first)
        restore.cancel()
        restoringManager = nil
        XCTAssertNil(weakRestoringManager)
        restore.perform()

        shouldDeferActivation = true
        var deferredManager: ClipboardManager? = makeManager()
        weak let weakDeferredManager = deferredManager
        _ = deferredManager?.paste(
            records: [record], merged: false, plainTextOnly: false, activating: nil
        )
        let activationCallback = try XCTUnwrap(deferredActivation)
        deferredActivation = nil
        deferredManager = nil
        XCTAssertNil(weakDeferredManager)
        activationCallback(.ready)
    }
}
