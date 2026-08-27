import AppKit
import XCTest

@testable import Hyper

final class SensitiveClipboardPolicyTests: XCTestCase {
    private var root: URL!
    private var vault: ClipboardVault!
    private var store: ClipStore!
    private var queue: PasteQueue!
    private var pasteboard: NSPasteboard!
    private var monitor: ClipboardMonitor!
    private var manager: ClipboardManager!
    private var now: Date!
    private var sendPasteResult: Result<Paster.EventDelivery, Paster.EventFailure>!
    private var accessibilityStatus: Permissions.AccessibilityStatus!
    private var deferActivation = false
    private var pendingActivation: ((Paster.ActivationResult) -> Void)?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-sensitive-tests-\(UUID().uuidString)", isDirectory: true)
        vault = ClipboardVault(
            provider: EphemeralClipboardVaultKeyProvider(scope: UUID().uuidString)
        )
        try loadStore()
        pasteboard = .withUniqueName()
        pasteboard.clearContents()
        monitor = ClipboardMonitor(pasteboard: pasteboard)
        now = Date(timeIntervalSince1970: 10_000)
        sendPasteResult = .success(Paster.EventDelivery(eventCount: 2))
        accessibilityStatus = .granted
        deferActivation = false
        pendingActivation = nil
    }

    override func tearDownWithError() throws {
        manager?.applicationWillTerminate(drainTimeout: 1)
        pasteboard?.clearContents()
        try? FileManager.default.removeItem(at: root)
        manager = nil
        monitor = nil
        pasteboard = nil
        queue = nil
        store = nil
        vault = nil
        root = nil
    }

    private func loadStore() throws {
        store = ClipStore(root: root, vault: vault)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        queue = PasteQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.restore()
    }

    private func makeManager(settings: ClipboardSettings) -> ClipboardManager {
        let environment = ClipboardManager.PasteEnvironment(
            pasteboard: pasteboard,
            accessibilityStatus: { [weak self] in self?.accessibilityStatus ?? .denied },
            activate: { [weak self] _, completion in
                guard let self else { return }
                if self.deferActivation {
                    self.pendingActivation = completion
                } else {
                    completion(.ready)
                }
            },
            sendPaste: { [weak self] in
                guard let self else { return .failure(.eventSourceUnavailable) }
                return self.sendPasteResult
            },
            scheduleRestore: { _, _ in },
            afterHyperRelease: { body in body() }
        )
        let result = ClipboardManager(
            store: store,
            queue: queue,
            settings: settings,
            pasteEnvironment: environment,
            monitor: monitor,
            now: { [weak self] in self?.now ?? .distantPast }
        )
        manager = result
        result.apply(settings, applicationEnabled: true)
        return result
    }

    private func writeText(_ text: String, markers: [String] = []) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in markers {
            item.setData(Data([1]), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }

    private func capture(_ text: String, markers: [String] = [], expectedCount: Int = 1) {
        writeText(text, markers: markers)
        monitor.check(source: .unknown)
        let deadline = Date().addingTimeInterval(2)
        while store.records.count != expectedCount, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        if expectedCount == 0 {
            // A rejected capture has no history notification. Leave the worker enough
            // time to complete so an accidentally delayed insert cannot make a false pass.
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTAssertEqual(store.records.count, expectedCount)
    }

    func testRiskClassifierExplainsConcealedOTPPasswordAndPrivateKey() {
        XCTAssertEqual(
            SensitiveClipboardPolicy.classify(
                offeredTypes: ["org.nspasteboard.ConcealedType"], text: "hunter2"
            ),
            .concealed
        )
        XCTAssertEqual(
            SensitiveClipboardPolicy.classify(
                offeredTypes: [], text: "Your verification code is 482 193"
            ),
            .oneTimeCode
        )
        XCTAssertEqual(
            SensitiveClipboardPolicy.classify(offeredTypes: [], text: "T1ght!Password#42"),
            .password
        )
        XCTAssertEqual(
            SensitiveClipboardPolicy.classify(
                offeredTypes: [],
                text: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
            ),
            .privateKey
        )
    }

    func testDestructiveClassifierRejectsStructuredAndNumericFalsePositives() {
        let negatives = [
            "https://GitHub.com/OpenAI/gpt-5",
            "GitHub.com/OpenAI/gpt-5",
            "/Applications/Hyper 2.app/Contents/MacOS/Hyper",
            "Release=Build1!",
            "git tag v5.6.0-beta1",
            "swift build -c release --product Hyper5!",
            "version V5.6.0!Release",
            "build Build1!Release",
            "product code 123456789",
            "error code 482193",
            "postal code 482193",
            "ZIP 48219",
            "tracking 12345678901234567890",
        ]
        for value in negatives {
            XCTAssertNil(
                SensitiveClipboardPolicy.classify(offeredTypes: [], text: value),
                "must not classify structured/non-secret text: \(value)"
            )
        }
    }

    func testConcealedMarkerIsNeverSavedByDefault() {
        let settings = ClipboardSettings()
        _ = makeManager(settings: settings)

        capture("password", markers: ["org.nspasteboard.ConcealedType"], expectedCount: 0)

        XCTAssertTrue(store.records.isEmpty)
    }

    func testPinnedURLFalsePositiveSurvivesDefaultSensitiveTTL() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .expire
        settings.sensitiveTTLMinutes = 5
        _ = makeManager(settings: settings)
        capture("https://GitHub.com/OpenAI/gpt-5")
        let record = try XCTUnwrap(store.records.first)
        store.togglePin(record.id)

        now = now.addingTimeInterval(301)
        manager.refreshPrivacyState()

        let survivor = try XCTUnwrap(store.record(id: record.id))
        XCTAssertTrue(survivor.pinned)
        XCTAssertNil(survivor.sensitivity)
        XCTAssertNil(survivor.expiry)
        XCTAssertNotNil(store.payload(for: record.id))
    }

    func testSensitivePoliciesSkipExpireAndOneTime() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .skip
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193", expectedCount: 0)
        XCTAssertTrue(store.records.isEmpty)

        manager.stop()
        monitor = ClipboardMonitor(pasteboard: pasteboard)
        settings.sensitiveHandling = .expire
        settings.sensitiveTTLMinutes = 5
        _ = makeManager(settings: settings)
        capture("T1ght!Password#42")
        var record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.sensitivity, .password)
        XCTAssertNil(record.expiry, "password heuristics are label-only, never destructive")
        XCTAssertEqual(record.oneTime, false)

        store.clearAll()
        manager.stop()
        monitor = ClipboardMonitor(pasteboard: pasteboard)
        settings.sensitiveHandling = .oneTime
        _ = makeManager(settings: settings)
        capture("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")
        record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.sensitivity, .privateKey)
        XCTAssertEqual(record.oneTime, true)
        XCTAssertEqual(record.expiry, now.addingTimeInterval(300))
    }

    func testExpiredSensitiveRecordConvergesPermanentlyAfterRestart() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .expire
        settings.sensitiveTTLMinutes = 1
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193")
        let id = try XCTUnwrap(store.records.first?.id)
        store.togglePin(id)
        XCTAssertTrue(try XCTUnwrap(store.record(id: id)).pinned)
        XCTAssertTrue(store.flushNow())
        manager.applicationWillTerminate()
        manager = nil
        store = nil
        queue = nil

        now = now.addingTimeInterval(61)
        try loadStore()
        monitor = ClipboardMonitor(pasteboard: pasteboard)
        _ = makeManager(settings: settings)
        manager.refreshPrivacyState()

        XCTAssertNil(store.record(id: id))
        XCTAssertNil(store.payload(for: id), "expiry is permanent, not an undoable UI delete")
    }

    func testOneTimeRecordDeletesOnlyAfterSuccessfulPasteCommit() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .oneTime
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193")
        var record = try XCTUnwrap(store.records.first)

        sendPasteResult = .failure(.eventPostingFailed(keyDown: true))
        var failed: ClipboardOperationResult?
        _ = manager.paste(
            records: [record], merged: false, plainTextOnly: false, activating: nil
        ) { failed = $0 }
        XCTAssertFalse(try XCTUnwrap(failed).succeeded)
        XCTAssertNotNil(store.record(id: record.id))

        sendPasteResult = .success(Paster.EventDelivery(eventCount: 2))
        var succeeded: ClipboardOperationResult?
        _ = manager.paste(
            records: [record], merged: false, plainTextOnly: false, activating: nil
        ) { succeeded = $0 }
        XCTAssertTrue(try XCTUnwrap(succeeded).succeeded)
        XCTAssertNil(store.record(id: record.id))
        XCTAssertNil(store.payload(for: record.id))

        capture("Your verification code is 739104")
        record = try XCTUnwrap(store.records.first)
        accessibilityStatus = .denied
        let rejected = manager.paste(
            records: [record], merged: false, plainTextOnly: false, activating: nil
        )
        guard case .rejected(let result) = rejected else {
            return XCTFail("permission refusal must reject synchronously")
        }
        XCTAssertEqual(result.failure, .accessibilityPermissionDenied)
        XCTAssertNotNil(store.record(id: record.id))
    }

    func testQueuedOneTimeDeletesOnlyAfterDurableDequeueCommit() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .oneTime
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193")
        let record = try XCTUnwrap(store.records.first)
        queue.enqueue(record.id)
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }

        XCTAssertTrue(try XCTUnwrap(completion).succeeded)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(store.record(id: record.id))
        XCTAssertNil(store.payload(for: record.id))
    }

    func testQueuedOneTimeSurvivesDequeuePersistenceFailure() throws {
        let directoryAsQueueFile = root.appendingPathComponent(
            "queue-persistence-failure", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryAsQueueFile, withIntermediateDirectories: true
        )
        queue = PasteQueue(storeURL: directoryAsQueueFile)
        queue.restore()
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .oneTime
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193")
        let record = try XCTUnwrap(store.records.first)
        queue.enqueue(record.id)
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }

        XCTAssertEqual(
            completion?.failure,
            .eventDelivery(.queueCommit(.persistenceFailed(id: record.id)))
        )
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertNotNil(store.record(id: record.id))
        XCTAssertNotNil(store.payload(for: record.id))
    }

    func testQueuedOneTimeSurvivesEventDeliveryFailure() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .oneTime
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193")
        let record = try XCTUnwrap(store.records.first)
        queue.enqueue(record.id)
        sendPasteResult = .failure(.eventPostingFailed(keyDown: true))
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }

        XCTAssertEqual(
            completion?.failure, .eventDelivery(.eventPostingFailed(keyDown: true))
        )
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertNotNil(store.record(id: record.id))
        XCTAssertNotNil(store.payload(for: record.id))
    }

    func testQueuedOneTimeSurvivesPermissionRefusal() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .oneTime
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193")
        let record = try XCTUnwrap(store.records.first)
        queue.enqueue(record.id)
        accessibilityStatus = .denied
        var completion: ClipboardOperationResult?

        let dispatch = manager.pasteNext { completion = $0 }

        guard case .rejected(let result) = dispatch else {
            return XCTFail("permission refusal must reject the queued transaction")
        }
        XCTAssertEqual(result.failure, .accessibilityPermissionDenied)
        XCTAssertEqual(completion, result)
        XCTAssertEqual(queue.ids, [record.id])
        XCTAssertNotNil(store.record(id: record.id))
        XCTAssertNotNil(store.payload(for: record.id))
    }

    func testQueuedOneTimeSurvivesInvalidatedDequeueCommit() throws {
        var settings = ClipboardSettings()
        settings.sensitiveHandling = .oneTime
        _ = makeManager(settings: settings)
        capture("Your verification code is 482193")
        let record = try XCTUnwrap(store.records.first)
        let second = store.insert(
            ClipStore.Insertion(
                payload: [["public.utf8-plain-text": Data("ordinary".utf8)]],
                kind: .text, oversized: false, byteSize: 8,
                sourceBundleID: nil, sourceName: nil
            )
        )
        queue.enqueue(contentsOf: [record.id, second.id])
        deferActivation = true
        var completion: ClipboardOperationResult?

        _ = manager.pasteNext { completion = $0 }
        queue.moveDown(record.id)
        let activation = try XCTUnwrap(pendingActivation)
        pendingActivation = nil
        activation(.ready)

        XCTAssertEqual(
            completion?.failure,
            .eventDelivery(
                .queueCommit(.invalidated(expectedID: record.id, currentHead: second.id))
            )
        )
        XCTAssertEqual(queue.ids, [second.id, record.id])
        XCTAssertNotNil(store.record(id: record.id))
        XCTAssertNotNil(store.payload(for: record.id))
    }

    func testTemporaryPauseCapturesNothingAndResumeDoesNotBackfill() {
        var settings = ClipboardSettings()
        settings.pauseUntil = now.addingTimeInterval(900)
        _ = makeManager(settings: settings)

        writeText("copied while privacy pause is active")
        monitor.check(source: .unknown)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(manager.pauseState?.reason, .manualPrivacyPause)

        now = now.addingTimeInterval(901)
        manager.refreshPrivacyState()
        monitor.check(source: .unknown)
        XCTAssertTrue(store.records.isEmpty, "resume must baseline the paused clipboard")

        capture("copied after resume")
        XCTAssertEqual(store.records.map(\.preview), ["copied after resume"])
        XCTAssertNil(manager.pauseState)
    }

    func testSensitivePolicyAndPrivacyPauseRoundTripInIsolatedConfig() throws {
        let previous = ConfigStore.directoryOverride
        ConfigStore.directoryOverride = root.appendingPathComponent("config", isDirectory: true)
        defer { ConfigStore.directoryOverride = previous }
        var config = Config()
        config.clipboard.sensitiveHandling = .oneTime
        config.clipboard.sensitiveTTLMinutes = 17
        config.clipboard.pauseUntil = Date().addingTimeInterval(3_600)

        XCTAssertTrue(ConfigStore.save(config))
        let loaded = try XCTUnwrap(ConfigStore.load())
        XCTAssertEqual(loaded.clipboard.sensitiveHandling, .oneTime)
        XCTAssertEqual(loaded.clipboard.sensitiveTTLMinutes, 17)
        let loadedPause = try XCTUnwrap(loaded.clipboard.pauseUntil?.timeIntervalSince1970)
        let savedPause = try XCTUnwrap(config.clipboard.pauseUntil?.timeIntervalSince1970)
        XCTAssertEqual(loadedPause, savedPause, accuracy: 0.001)
    }

    func testLegacyRecordWithoutPrivacyKeysDecodesAsOrdinary() throws {
        let original = ClipRecord(
            id: UUID(), createdAt: now, kind: .text, preview: "legacy", digest: "digest",
            byteSize: 6, sourceBundleID: nil, sourceName: nil
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["sensitivity"] = nil
        object["expiry"] = nil
        object["oneTime"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClipRecord.self, from: legacy)
        XCTAssertNil(decoded.sensitivity)
        XCTAssertNil(decoded.expiry)
        XCTAssertFalse(decoded.oneTime)
    }
}
