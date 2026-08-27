import AppKit
import XCTest

@testable import Hyper

final class ClipboardPrivacyLifecycleTests: XCTestCase {
    private var root: URL!
    private var store: ClipStore!
    private var queue: PasteQueue!
    private var pasteboard: NSPasteboard!
    private var monitor: ClipboardMonitor!
    private var manager: ClipboardManager!
    private var activeSource: ClipboardCaptureSource?
    private var currentTime: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-privacy-tests-\(UUID().uuidString)", isDirectory: true)
        store = ClipStore(root: root)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        queue = PasteQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.restore()
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        currentTime = Date(timeIntervalSince1970: 1_000)
        monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            activeApplication: { [unowned self] in self.activeSource },
            now: { [unowned self] in self.currentTime }
        )
    }

    override func tearDownWithError() throws {
        manager?.applicationWillTerminate(drainTimeout: 1)
        pasteboard?.clearContents()
        try? FileManager.default.removeItem(at: root)
        manager = nil
        monitor = nil
        activeSource = nil
        currentTime = nil
        pasteboard = nil
        queue = nil
        store = nil
        root = nil
    }

    private func makeManager(
        settings: ClipboardSettings = ClipboardSettings(),
        drainStore: ((TimeInterval) -> Bool)? = nil
    ) -> ClipboardManager {
        let environment = ClipboardManager.PasteEnvironment(
            pasteboard: pasteboard,
            accessibilityStatus: { .granted },
            activate: { _, completion in completion(.ready) },
            sendPaste: { .success(Paster.EventDelivery(eventCount: 2)) },
            scheduleRestore: { _, _ in },
            afterHyperRelease: { body in body() }
        )
        let result = ClipboardManager(
            store: store,
            queue: queue,
            settings: settings,
            pasteEnvironment: environment,
            monitor: monitor,
            drainStore: drainStore
        )
        manager = result
        return result
    }

    @discardableResult
    private func writeText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    private func writeRichText(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data("<b>\(text)</b>".utf8), forType: .html)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }

    private func writeImage() {
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png)
    }

    private func source(_ bundleID: String, pid: Int32 = 101) -> ClipboardCaptureSource {
        ClipboardCaptureSource(
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            localizedName: bundleID,
            attribution: .copyKeystroke
        )
    }

    private func persistedRecords() throws -> [ClipRecord] {
        let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let legacy = try? decoder.decode([ClipRecord].self, from: data) { return legacy }
        struct Envelope: Decodable { let records: [ClipRecord] }
        return try decoder.decode(Envelope.self, from: data).records
    }

    func testGlobalPauseWritesNothingAndResumeDoesNotBackfillPausedContent() {
        let manager = makeManager()
        manager.apply(ClipboardSettings(), applicationEnabled: false)

        writeText("copied while paused")
        monitor.check(source: source("com.example.allowed"))
        XCTAssertTrue(store.records.isEmpty, "a global pause must gate capture, not only hotkeys")

        manager.apply(ClipboardSettings(), applicationEnabled: true)
        monitor.check()
        XCTAssertTrue(store.records.isEmpty, "resuming must accept the current clipboard as baseline")

        writeText("copied after resume")
        monitor.check(source: source("com.example.allowed"))
        XCTAssertEqual(store.records.map(\.preview), ["copied after resume"])
    }

    func testCopySourceSnapshotSurvivesSwitchingApplicationsBeforeCapture() {
        let manager = makeManager()
        manager.apply(ClipboardSettings(), applicationEnabled: true)
        let copyingApplication = source("com.example.secret", pid: 700)

        activeSource = copyingApplication
        _ = monitor.checkSoon(source: copyingApplication)
        writeText("source stays attached")
        // The pasteboard transaction is already visible when activation changes, so it
        // belongs to the old application even though the delayed timer has not run yet.
        activeSource = source("com.example.next", pid: 701)
        monitor.applicationDidChange(to: activeSource)

        XCTAssertEqual(store.records.first?.sourceBundleID, "com.example.secret")
        XCTAssertEqual(store.records.first?.sourceName, "com.example.secret")
    }

    func testIgnoredCopySourceCannotLeakAcrossOneHundredImmediateAppSwitches() {
        var settings = ClipboardSettings()
        settings.applicationRules = ["com.example.secret": .ignore]
        let manager = makeManager(settings: settings)
        manager.apply(settings, applicationEnabled: true)

        for index in 0..<100 {
            let copyingApplication = source("com.example.secret", pid: 700)
            activeSource = copyingApplication
            _ = monitor.checkSoon(source: copyingApplication)
            writeText("secret \(index)")
            activeSource = source("com.example.next", pid: 701)
            monitor.applicationDidChange(to: activeSource)
        }

        XCTAssertTrue(store.records.isEmpty)
    }

    func testPendingSourceIsNotBorrowedByANewUnkeyedChange() {
        let oldSource = source("com.example.allowed", pid: 700)
        activeSource = oldSource
        _ = monitor.checkSoon(source: oldSource)
        var observed: ClipboardCaptureSource?
        monitor.onChange = { observed = $0 }

        writeText("right-click copy")
        monitor.check()

        XCTAssertEqual(observed, .unknown)
    }

    func testPendingSourceRequiresExactNextChangeCountAndShortWindow() {
        let copyingApplication = source("com.example.allowed", pid: 700)
        activeSource = copyingApplication
        var observed: [ClipboardCaptureSource] = []
        monitor.onChange = { observed.append($0) }

        let skippedExpectedCount = monitor.checkSoon(source: copyingApplication)
        pasteboard.clearContents()
        writeText("two mutations later")
        monitor.check(expectedChangeCount: skippedExpectedCount)
        XCTAssertEqual(observed.last, .unknown)

        let expiredExpectedCount = monitor.checkSoon(source: copyingApplication)
        currentTime = currentTime.addingTimeInterval(0.76)
        writeText("too late")
        monitor.check(expectedChangeCount: expiredExpectedCount)
        XCTAssertEqual(observed.last, .unknown)
    }

    func testStaleAllowedAndIgnoredSourcesNeverCrossApplicationBoundaryForOneHundredRounds() {
        let allowed = source("com.example.allowed", pid: 700)
        let ignored = source("com.example.ignored", pid: 701)
        var observed: [ClipboardCaptureSource] = []
        monitor.onChange = { observed.append($0) }

        for index in 0..<100 {
            activeSource = allowed
            _ = monitor.checkSoon(source: allowed)
            activeSource = ignored
            monitor.applicationDidChange(to: ignored)
            writeText("ignored menu copy \(index)")
            monitor.check()
            XCTAssertEqual(observed.last, .unknown, "allowed source leaked on round \(index)")

            activeSource = ignored
            _ = monitor.checkSoon(source: ignored)
            activeSource = allowed
            monitor.applicationDidChange(to: allowed)
            writeText("allowed menu copy \(index)")
            monitor.check()
            XCTAssertEqual(observed.last, .unknown, "ignored source caused a false drop on round \(index)")
        }

        XCTAssertEqual(observed.count, 200)
    }

    func testUnknownPollingSourceUsesMostRestrictiveConfiguredRule() {
        var settings = ClipboardSettings()
        settings.applicationRules = ["com.example.secret": .ignore]
        let manager = makeManager(settings: settings)
        manager.apply(settings, applicationEnabled: true)

        writeText("must not bypass unknown-source privacy")
        monitor.check()

        XCTAssertTrue(store.records.isEmpty)
    }

    func testUnknownPollingSourceIsStoredWithoutFalseAttributionWhenNoRulesExist() {
        let manager = makeManager()
        manager.apply(ClipboardSettings(), applicationEnabled: true)

        writeText("menu copy")
        monitor.check()

        XCTAssertEqual(store.records.first?.preview, "menu copy")
        XCTAssertNil(store.records.first?.sourceBundleID)
        XCTAssertNil(store.records.first?.sourceName)
    }

    func testIgnoreTextOnlyAndNoImagesRulesAreEnforcedAtCapture() throws {
        var settings = ClipboardSettings()
        settings.applicationRules = [
            "com.example.ignore": .ignore,
            "com.example.text": .textOnly,
            "com.example.noimages": .noImages,
        ]
        let manager = makeManager(settings: settings)
        manager.apply(settings, applicationEnabled: true)

        writeText("ignored")
        monitor.check(source: source("com.example.ignore"))
        XCTAssertTrue(store.records.isEmpty)

        writeRichText("plain survives")
        monitor.check(source: source("com.example.text"))
        let textRecord = try XCTUnwrap(store.records.first)
        XCTAssertEqual(textRecord.kind, .text)
        XCTAssertEqual(textRecord.sourceBundleID, "com.example.text")
        store.waitForPendingWrites()
        XCTAssertEqual(
            Set(try XCTUnwrap(store.payload(for: textRecord.id)).flatMap(\.keys)),
            Set([NSPasteboard.PasteboardType.string.rawValue])
        )

        writeImage()
        monitor.check(source: source("com.example.noimages"))
        XCTAssertEqual(store.records.count, 1, "noImages must reject image captures before insertion")

        writeText("text is still allowed")
        monitor.check(source: source("com.example.noimages"))
        XCTAssertEqual(store.records.first?.preview, "text is still allowed")
        XCTAssertEqual(store.records.count, 2)
    }

    func testShutdownReportsSuccessfulBoundedStoreDrain() {
        var receivedTimeout: TimeInterval?
        let manager = makeManager(drainStore: { timeout in
            receivedTimeout = timeout
            return true
        })

        let result = manager.applicationWillTerminate(drainTimeout: 0.25)

        XCTAssertNotNil(receivedTimeout)
        XCTAssertGreaterThan(receivedTimeout ?? 0, 0)
        XCTAssertLessThanOrEqual(receivedTimeout ?? 1, 0.25)
        XCTAssertEqual(result, .drained)
    }

    func testShutdownUsesRealStoreDrainAndReturnsOnlyAfterIndexIsDurable() throws {
        let manager = makeManager()
        manager.apply(ClipboardSettings(), applicationEnabled: true)
        writeText("durable on quit")
        monitor.check(source: source("com.example.allowed"))
        let id = try XCTUnwrap(store.records.first?.id)

        XCTAssertEqual(manager.applicationWillTerminate(drainTimeout: 2), .drained)

        XCTAssertTrue(try persistedRecords().contains { $0.id == id })
        XCTAssertNotNil(store.payload(for: id))
    }

    func testShutdownReportsIncompleteDrainWithoutRetryingForever() {
        var attempts = 0
        let manager = makeManager(drainStore: { _ in
            attempts += 1
            return false
        })

        let result = manager.applicationWillTerminate(drainTimeout: 0.01)

        XCTAssertEqual(attempts, 1)
        guard case .incomplete(
            timeout: 0.01, queue: .drained, storeDrained: false
        ) = result else {
            return XCTFail("expected a structured store drain failure, got \(result)")
        }
    }

    func testShutdownQueueAndStoreShareOneHardTimeoutBudget() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue = PasteQueue(
            storeURL: root.appendingPathComponent("queue.json"),
            persistenceBarrier: {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        )
        queue.restore()
        queue.enqueue(UUID())
        var storeTimeout: TimeInterval?
        let manager = makeManager(drainStore: { timeout in
            storeTimeout = timeout
            return false
        })
        let started = ProcessInfo.processInfo.systemUptime

        let result = manager.applicationWillTerminate(drainTimeout: 0.03)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 0.18)
        XCTAssertLessThanOrEqual(storeTimeout ?? 1, 0.03)
        guard case .incomplete(
            timeout: 0.03, queue: .timedOut(timeout: 0.03), storeDrained: false
        ) = result else {
            release.signal()
            return XCTFail("expected a structured queue timeout, got \(result)")
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 0.1), .success)
        release.signal()
    }
}
