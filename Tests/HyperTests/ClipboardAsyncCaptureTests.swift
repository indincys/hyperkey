import AppKit
import XCTest

@testable import Hyper

final class ClipboardAsyncCaptureTests: XCTestCase {
    private final class LazyProvider: NSObject, NSPasteboardItemDataProvider {
        let size: Int
        let delay: TimeInterval
        private(set) var providedOnMainThread: Bool?

        init(size: Int, delay: TimeInterval = 0) {
            self.size = size
            self.delay = delay
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            providedOnMainThread = Thread.isMainThread
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            item.setData(Data(count: size), forType: type)
        }
    }

    func testWorkerSubmissionIsFastAndBacklogCoalescesToOne() {
        let started = expectation(description: "active reader started")
        let gate = DispatchSemaphore(value: 0)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("one", forType: .string)
        let worker = ClipboardCaptureWorker(
            timeout: 5,
            reader: { _, _ in
                started.fulfill()
                gate.wait()
                return .ignored("released")
            }
        )

        worker.submit(
            pasteboard: pasteboard, expectedChangeCount: pasteboard.changeCount,
            options: ClipCapture.Options()
        ) { _, done in done() }
        wait(for: [started], timeout: 1)

        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            worker.submit(
                pasteboard: pasteboard, expectedChangeCount: pasteboard.changeCount,
                options: ClipCapture.Options()
            ) { _, done in done() }
        }
        let schedulingTime = ProcessInfo.processInfo.systemUptime - began
        let snapshot = worker.snapshot

        XCTAssertLessThan(schedulingTime, 0.05, "100 main-thread submissions must remain scheduling-only")
        XCTAssertEqual(snapshot.inflight, 1)
        XCTAssertEqual(snapshot.backlog, 1)
        XCTAssertEqual(snapshot.maximumInflight, 1)
        XCTAssertEqual(snapshot.maximumBacklog, 1)
        XCTAssertEqual(snapshot.coalesced, 99)
        gate.signal()
    }

    func testSlowProviderDoesNotBlockMainAndReportsHonestTimeout() {
        let pasteboard = NSPasteboard.withUniqueName()
        let provider = LazyProvider(size: 64, delay: 0.2)
        pasteboard.clearContents()
        pasteboard.setString("metadata only", forType: .string)
        let completed = expectation(description: "timed out provider eventually returned")
        let worker = ClipboardCaptureWorker(timeout: 0.05) { _, options in
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            return ClipCapture.read(items: [item], options: options)
        }

        let began = ProcessInfo.processInfo.systemUptime
        worker.submit(
            pasteboard: pasteboard, expectedChangeCount: pasteboard.changeCount,
            options: ClipCapture.Options()
        ) { result, done in
            guard case .timedOut(let elapsed) = result else {
                done()
                return XCTFail("slow provider must be reported as timed out, got \(result)")
            }
            XCTAssertGreaterThanOrEqual(elapsed, 0.2)
            done()
            completed.fulfill()
        }
        let schedulingTime = ProcessInfo.processInfo.systemUptime - began

        XCTAssertLessThan(schedulingTime, 0.016)
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(provider.providedOnMainThread, false)
    }

    func testTwentyTwoHundredAndFiveHundredMegabyteProvidersScheduleUnderFrameBudget() {
        for size in [20, 200, 500].map({ $0 * 1024 * 1024 }) {
            autoreleasepool {
                let pasteboard = NSPasteboard.withUniqueName()
                pasteboard.clearContents()
                pasteboard.setString("metadata only", forType: .string)
                let completed = expectation(description: "capture \(size)")
                var readerWasMainThread: Bool?
                // Logical-size seam: the budget outcome is tiny, so this regression
                // proves scheduling/backpressure at 20/200/500 MB without reserving a
                // real 720 MB in the test process. Actual provider materialisation is
                // covered separately by the delayed-provider test above.
                let worker = ClipboardCaptureWorker(timeout: 5) { _, _ in
                    readerWasMainThread = Thread.isMainThread
                    var reduction = ClipCapture.Reduction()
                    reduction.oversized = true
                    reduction.byteSize = size
                    reduction.observedByteSize = size
                    return .captured(
                        [[ClipCapture.oversizedMetadataType: Data([0])]], .text, reduction
                    )
                }
                var options = ClipCapture.Options()
                options.maxItemBytes = 1 * 1024 * 1024

                let began = ProcessInfo.processInfo.systemUptime
                worker.submit(
                    pasteboard: pasteboard, expectedChangeCount: pasteboard.changeCount,
                    options: options
                ) { result, done in
                    defer {
                        done()
                        completed.fulfill()
                    }
                    guard case .completed(.captured(_, _, let reduction), _) = result else {
                        return XCTFail("expected oversized capture, got \(result)")
                    }
                    XCTAssertTrue(reduction.oversized)
                    XCTAssertEqual(reduction.observedByteSize, size)
                }
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.016)
                wait(for: [completed], timeout: 10)
                XCTAssertEqual(readerWasMainThread, false)
            }
        }
    }

    func testManagerSchedulesSlowCaptureUnderFrameBudgetAndCommitsConsistently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-async-capture-\(UUID().uuidString)", isDirectory: true)
        let store = ClipStore(root: root)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        let queue = PasteQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.restore()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("captured consistently", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        var readerWasMainThread: Bool?
        let captureWorker = ClipboardCaptureWorker(timeout: 1) { pasteboard, options in
            readerWasMainThread = Thread.isMainThread
            Thread.sleep(forTimeInterval: 0.1)
            return ClipCapture.read(pasteboard, options: options)
        }
        let environment = ClipboardManager.PasteEnvironment(
            pasteboard: pasteboard,
            accessibilityStatus: { .granted },
            activate: { _, completion in completion(.ready) },
            sendPaste: { .success(Paster.EventDelivery(eventCount: 2)) },
            scheduleRestore: { _, _ in },
            afterHyperRelease: { body in body() }
        )
        let manager = ClipboardManager(
            store: store, queue: queue, settings: ClipboardSettings(),
            pasteEnvironment: environment, monitor: monitor,
            captureWorker: captureWorker
        )
        defer {
            manager.applicationWillTerminate(drainTimeout: 2)
            try? FileManager.default.removeItem(at: root)
        }
        manager.apply(ClipboardSettings(), applicationEnabled: true)
        // Start accepts the current value as baseline; make this a new transaction.
        pasteboard.clearContents()
        pasteboard.setString("captured consistently", forType: .string)
        let committed = expectation(
            forNotification: ClipboardManager.historyChanged, object: nil
        )
        let source = ClipboardCaptureSource(
            processIdentifier: 42, bundleIdentifier: "com.example.source",
            localizedName: "Source", attribution: .copyKeystroke
        )

        let began = ProcessInfo.processInfo.systemUptime
        monitor.check(source: source)
        let schedulingTime = ProcessInfo.processInfo.systemUptime - began

        XCTAssertLessThan(schedulingTime, 0.016)
        wait(for: [committed], timeout: 2)
        XCTAssertEqual(readerWasMainThread, false)
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.preview, "captured consistently")
        XCTAssertEqual(record.sourceBundleID, "com.example.source")
        XCTAssertEqual(record.digest, ClipPayloadCoder.digest([
            [NSPasteboard.PasteboardType.string.rawValue: Data("captured consistently".utf8)]
        ]))
        XCTAssertTrue(store.drainPendingWrites(timeout: 2))
        XCTAssertEqual(
            ClipCapture.plainText(from: try XCTUnwrap(store.payload(for: record.id))),
            "captured consistently"
        )
    }
}
