import AppKit
import Darwin
import ImageIO
import XCTest

@testable import Hyper

final class ClipPreviewCacheTests: XCTestCase {
    private final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak: UInt64

        init(baseline: UInt64) { peak = baseline }

        func observe(_ value: UInt64) {
            lock.lock(); peak = max(peak, value); lock.unlock()
        }

        func shouldContinue() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return running
        }

        func stop() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            running = false
            return peak
        }
    }

    private func makeStore(at root: URL) -> ClipStore {
        let store = ClipStore(root: root)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        return store
    }

    private func png720() throws -> Data {
        let width = 720
        let height = 720
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func imageInsertion(_ index: Int, thumbnail: Data) -> ClipStore.Insertion {
        let payload: ClipPayload = [["public.png": thumbnail]]
        return ClipStore.Insertion(
            payload: payload, kind: .image, oversized: false,
            byteSize: thumbnail.count, sourceBundleID: "tests.preview",
            sourceName: "Preview tests",
            prepared: ClipStore.CapturePreparation(
                digest: "production-thumbnail-\(index)", preview: "image-\(index)",
                searchEntry: nil, contentTag: nil, fileCount: nil, colorHex: nil,
                image: ClipStore.PreparedImage(
                    pixelWidth: 720, pixelHeight: 720, thumbnailData: thumbnail
                )
            )
        )
    }

    private func fileInsertion(_ index: Int, url: URL) -> ClipStore.Insertion {
        let payload: ClipPayload = [["public.file-url": Data(url.absoluteString.utf8)]]
        return ClipStore.Insertion(
            payload: payload, kind: .files, oversized: false,
            byteSize: ClipPayloadCoder.byteSize(payload), sourceBundleID: "tests.preview",
            sourceName: "Preview tests",
            prepared: ClipStore.CapturePreparation(
                digest: ClipPayloadCoder.digest(payload), preview: url.lastPathComponent,
                searchEntry: nil, contentTag: nil, fileCount: 1, colorHex: nil, image: nil
            )
        )
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func record(
        _ index: Int, id: UUID = UUID(), generation: UInt64 = 1,
        kind: ClipKind = .image, byteSize: Int = 100
    ) -> ClipPreviewRequest {
        ClipPreviewRequest(
            record: ClipRecord(
                id: id,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                kind: kind,
                preview: "item-\(index)",
                digest: "digest-\(index)-\(generation)",
                byteSize: byteSize,
                sourceBundleID: nil,
                sourceName: nil,
                pinned: false,
                oversized: false,
                hasThumbnail: kind == .image
            ),
            generation: generation
        )
    }

    private func asset(_ index: Int) -> ClipPreviewAsset {
        let image = NSImage(size: NSSize(width: 8 + index % 3, height: 8))
        return ClipPreviewAsset(image: image, files: [], overflowFileCount: 0)
    }

    func testHardCostBudgetEvictsLeastRecentlyUsedEntry() {
        let lock = NSLock()
        var loads: [UUID: Int] = [:]
        let cache = ClipPreviewCache(
            configuration: .init(maxCost: 300, maxCount: 3),
            loader: { request in
                lock.lock()
                loads[request.identity.id, default: 0] += 1
                lock.unlock()
                return .success(self.asset(request.record.byteSize), cost: 150)
            }
        )
        let requests = (0..<3).map { self.record($0) }

        for request in requests {
            let done = expectation(description: "load \(request.record.preview)")
            let token = cache.request(request) { _ in done.fulfill() }
            wait(for: [done], timeout: 1)
            withExtendedLifetime(token) {}
        }
        XCTAssertLessThanOrEqual(cache.stats.currentCost, 300)
        XCTAssertLessThanOrEqual(cache.stats.entryCount, 2)

        let reload = expectation(description: "LRU entry reloads")
        let token = cache.request(requests[0]) { _ in reload.fulfill() }
        wait(for: [reload], timeout: 1)
        withExtendedLifetime(token) {}
        lock.lock()
        let oldestLoads = loads[requests[0].identity.id]
        lock.unlock()
        XCTAssertEqual(oldestLoads, 2)
    }

    func testDuplicateRequestsMergeAndCancelledSubscriberIsNotCalled() {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var loadCount = 0
        let cache = ClipPreviewCache(loader: { request in
            lock.lock(); loadCount += 1; lock.unlock()
            _ = gate.wait(timeout: .now() + 1)
            return .success(self.asset(request.record.byteSize), cost: 64)
        })
        let request = record(1)
        let cancelled = expectation(description: "cancelled completion")
        cancelled.isInverted = true
        let delivered = expectation(description: "live completion")

        let first = cache.request(request) { _ in cancelled.fulfill() }
        let second = cache.request(request) { _ in delivered.fulfill() }
        first.cancel()
        gate.signal()
        wait(for: [delivered, cancelled], timeout: 0.3)
        withExtendedLifetime(second) {}
        lock.lock(); let actualLoads = loadCount; lock.unlock()
        XCTAssertEqual(actualLoads, 1)
    }

    func testGenerationAndDigestPreventReusedRowFromReceivingOldImage() {
        let gate = DispatchSemaphore(value: 0)
        let id = UUID()
        let cache = ClipPreviewCache(loader: { request in
            if request.generation == 1 { _ = gate.wait(timeout: .now() + 1) }
            return .success(self.asset(Int(request.generation)), cost: 64)
        })
        let old = record(1, id: id, generation: 1)
        let new = record(2, id: id, generation: 2)
        let oldCompletion = expectation(description: "old cancelled")
        oldCompletion.isInverted = true
        let newCompletion = expectation(description: "new delivered")

        let oldToken = cache.request(old) { _ in oldCompletion.fulfill() }
        oldToken.cancel()
        let newToken = cache.request(new) { result in
            if case .ready = result { newCompletion.fulfill() }
        }
        gate.signal()
        wait(for: [newCompletion, oldCompletion], timeout: 0.3)
        withExtendedLifetime(newToken) {}
    }

    func testPanelCloseCancelsWorkAndDropsDecodedAssets() {
        let gate = DispatchSemaphore(value: 0)
        let cache = ClipPreviewCache(loader: { request in
            _ = gate.wait(timeout: .now() + 1)
            return .success(self.asset(request.record.byteSize), cost: 128)
        })
        let completion = expectation(description: "closed panel completion")
        completion.isInverted = true
        let token = cache.request(record(1)) { _ in completion.fulfill() }
        cache.handlePanelClosed()
        gate.signal()
        wait(for: [completion], timeout: 0.12)
        withExtendedLifetime(token) {}
        XCTAssertEqual(cache.stats.currentCost, 0)
        XCTAssertEqual(cache.stats.entryCount, 0)
        XCTAssertEqual(cache.stats.inFlightCount, 0)
    }

    func testTimeoutIsNegativelyCachedWithoutBlockingCaller() {
        let lock = NSLock()
        var loadCount = 0
        let cache = ClipPreviewCache(
            configuration: .init(
                maxCost: 1_024, maxCount: 8, loadTimeout: 0.025, negativeTTL: 0.25
            ),
            loader: { _ in
                lock.lock(); loadCount += 1; lock.unlock()
                Thread.sleep(forTimeInterval: 0.15)
                return .failure(.unavailable)
            }
        )
        let request = record(1)
        let first = expectation(description: "timeout")
        let started = CFAbsoluteTimeGetCurrent()
        let firstToken = cache.request(request) { result in
            if case .unavailable(.timedOut) = result { first.fulfill() }
        }
        wait(for: [first], timeout: 0.2)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 0.12)
        withExtendedLifetime(firstToken) {}

        let cached = expectation(description: "negative cache")
        let secondToken = cache.request(request) { result in
            if case .unavailable(.timedOut) = result { cached.fulfill() }
        }
        wait(for: [cached], timeout: 0.1)
        withExtendedLifetime(secondToken) {}
        lock.lock(); let cachedLoadCount = loadCount; lock.unlock()
        XCTAssertEqual(cachedLoadCount, 1)

        RunLoop.main.run(until: Date().addingTimeInterval(0.27))
        let expired = expectation(description: "negative cache expires")
        let thirdToken = cache.request(request) { result in
            if case .unavailable(.timedOut) = result { expired.fulfill() }
        }
        wait(for: [expired], timeout: 0.2)
        withExtendedLifetime(thirdToken) {}
        lock.lock(); let reloadedCount = loadCount; lock.unlock()
        XCTAssertEqual(reloadedCount, 2)
    }

    func testRapidScrollAcrossOneThousandMixedItemsStaysBoundedAndNeverLoadsOnMain() {
        let lock = NSLock()
        var mainThreadLoads = 0
        var loadCount = 0
        let cache = ClipPreviewCache(
            configuration: .init(
                maxCost: 256 * 1_024, maxCount: 64, workerCount: 4,
                loadTimeout: 1, negativeTTL: 0.1
            ),
            loader: { request in
                lock.lock()
                if Thread.isMainThread { mainThreadLoads += 1 }
                loadCount += 1
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.0005)
                return .success(self.asset(request.record.byteSize), cost: 8 * 1_024)
            }
        )
        let started = CFAbsoluteTimeGetCurrent()
        var active: [ClipPreviewRequestToken] = []
        let finalLoads = expectation(description: "final viewport")
        finalLoads.expectedFulfillmentCount = 24

        for index in 0..<1_000 {
            let kind: ClipKind = index.isMultiple(of: 3) ? .files : .image
            let token = cache.request(record(index, kind: kind, byteSize: index)) { _ in
                if index >= 976 { finalLoads.fulfill() }
            }
            active.append(token)
            if active.count > 24 { active.removeFirst().cancel() }
        }
        wait(for: [finalLoads], timeout: 2)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        withExtendedLifetime(active) {}

        lock.lock()
        let mainLoads = mainThreadLoads
        let actualLoads = loadCount
        lock.unlock()
        XCTAssertEqual(mainLoads, 0, "payload reads and image/file decode must stay off main")
        XCTAssertLessThan(actualLoads, 200, "cancelled off-screen requests should not all execute")
        XCTAssertLessThanOrEqual(cache.stats.currentCost, 256 * 1_024)
        XCTAssertLessThanOrEqual(cache.stats.entryCount, 64)
        XCTAssertLessThan(elapsed, 1.5)
        print("PREVIEW_PERF items=1000 loads=\(actualLoads) elapsed_ms=\(Int(elapsed * 1000)) cost=\(cache.stats.currentCost)")
    }

    func testProductionFileLoaderNeverTouchesFourRiskPathsAndFastImageIsNotStarved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-preview-risk-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let symlink = root.appendingPathComponent("offline-link.mov")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: URL(fileURLWithPath: "/Volumes/Offline/movie.mov")
        )
        let store = makeStore(at: root.appendingPathComponent("store", isDirectory: true))
        let risky = [
            URL(fileURLWithPath: "/Volumes/Offline/report.pdf"),
            URL(fileURLWithPath: "/Network/Servers/stalled/presentation.key"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/CloudStorage/OfflineDrive/archive.zip"
            ),
            symlink,
        ]
        let fileRecords = risky.enumerated().map { store.insert(fileInsertion($0, url: $1)) }
        let imageRecord = store.insert(imageInsertion(99, thumbnail: try png720()))
        store.waitForPendingWrites()

        let cache = ClipPreviewCache(
            configuration: .init(
                maxCost: 32 * 1_024 * 1_024, maxCount: 32, workerCount: 4,
                loadTimeout: 0.5, negativeTTL: 0.1
            ),
            loader: ClipPreviewCache.loader(store: store)
        )
        let placeholders = expectation(description: "four risky paths are placeholders")
        placeholders.expectedFulfillmentCount = 4
        let fast = expectation(description: "local stored image is not starved")
        let started = ProcessInfo.processInfo.systemUptime
        var tokens: [ClipPreviewRequestToken] = []
        for record in fileRecords {
            tokens.append(cache.request(ClipPreviewRequest(record: record, generation: 1)) { result in
                guard case .ready(let asset) = result,
                      asset.files.count == 1,
                      asset.files[0].unavailable,
                      asset.files[0].byteSize == nil
                else { return }
                placeholders.fulfill()
            })
        }
        tokens.append(cache.request(ClipPreviewRequest(record: imageRecord, generation: 1)) {
            result in
            if case .ready(let asset) = result, asset.image != nil { fast.fulfill() }
        })

        wait(for: [fast, placeholders], timeout: 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        withExtendedLifetime(tokens) {}
        XCTAssertLessThan(elapsed, 0.8, "risk paths must not occupy the four-worker pool")
        print("PREVIEW_STARVATION risk_paths=4 fast_image_ms=\(Int(elapsed * 1000))")
    }

    func testProductionLoaderThousand720ImagesHasOnePixelBudgetAndReleasesOnClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-preview-production-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)
        let thumbnail = try png720()
        var records: [ClipRecord] = []
        records.reserveCapacity(1_000)
        for index in 0..<1_000 {
            records.append(store.insert(imageInsertion(index, thumbnail: thumbnail)))
        }
        store.waitForPendingWrites()

        let cache = ClipPreviewCache(
            configuration: .init(
                maxCost: 32 * 1_024 * 1_024, maxCount: 96, workerCount: 4,
                loadTimeout: 2, negativeTTL: 0.1
            ),
            loader: ClipPreviewCache.loader(store: store)
        )
        let baseline = Self.physicalFootprint()
        let footprint = FootprintSampler(baseline: baseline)
        let sampler = DispatchQueue(label: "tests.preview-rss")
        sampler.async {
            while footprint.shouldContinue() {
                footprint.observe(Self.physicalFootprint())
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        let finalViewport = expectation(description: "final production viewport")
        finalViewport.expectedFulfillmentCount = 24
        let started = ProcessInfo.processInfo.systemUptime
        var active: [ClipPreviewRequestToken] = []
        for (index, record) in records.enumerated() {
            let token = cache.request(ClipPreviewRequest(record: record, generation: 1)) { result in
                if index >= 976, case .ready(let asset) = result, asset.image != nil {
                    finalViewport.fulfill()
                }
            }
            active.append(token)
            if active.count > 24 { active.removeFirst().cancel() }
        }
        wait(for: [finalViewport], timeout: 15)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let steady = Self.physicalFootprint()
        let steadyStats = cache.stats
        XCTAssertLessThanOrEqual(steadyStats.currentCost, 32 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(steadyStats.entryCount, 96)

        active.removeAll()
        cache.handlePanelClosed()
        let purgeDeadline = Date().addingTimeInterval(2)
        while cache.stats.entryCount != 0, Date() < purgeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let closed = Self.physicalFootprint()
        let measuredPeak = footprint.stop()
        sampler.sync {}

        XCTAssertEqual(cache.stats.currentCost, 0)
        XCTAssertEqual(cache.stats.entryCount, 0)
        XCTAssertEqual(cache.stats.inFlightCount, 0)
        if baseline > 0, measuredPeak > 0 {
            XCTAssertLessThan(
                measuredPeak - baseline, 256 * 1_024 * 1_024,
                "four decoders plus the 32 MB LRU must not create an unbounded second cache"
            )
            XCTAssertLessThanOrEqual(closed, measuredPeak + 8 * 1_024 * 1_024)
        }
        print(
            "PREVIEW_PRODUCTION_RSS items=1000 pixels=720x720 "
                + "baseline=\(baseline) peak=\(measuredPeak) steady=\(steady) close=\(closed) "
                + "cost=\(steadyStats.currentCost) entries=\(steadyStats.entryCount) "
                + "elapsed_ms=\(Int(elapsed * 1000))"
        )
    }
}
