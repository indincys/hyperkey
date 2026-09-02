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
                digest: "digest-\(index)",
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

    func testDigestChangePreventsReusedRowFromReceivingOldImage() {
        let gate = DispatchSemaphore(value: 0)
        let id = UUID()
        // Gated on the digest, not the generation: the digest is what the cache key
        // actually distinguishes these two requests by.
        let cache = ClipPreviewCache(loader: { request in
            if request.record.digest == "digest-1" { _ = gate.wait(timeout: .now() + 1) }
            return .success(self.asset(request.record.byteSize), cost: 64)
        })
        let old = record(1, id: id, generation: 1)
        let new = record(2, id: id, generation: 2)
        // The digest is the only thing separating them — same record id, same kind,
        // same thumbnail state, same pixel bucket.
        XCTAssertNotEqual(old.identity, new.identity)
        XCTAssertNotEqual(old.record.digest, new.record.digest)
        XCTAssertEqual(old.identity.id, new.identity.id)
        XCTAssertEqual(old.identity.kind, new.identity.kind)
        XCTAssertEqual(old.identity.hasThumbnail, new.identity.hasThumbnail)
        XCTAssertEqual(old.identity.maxPixelSize, new.identity.maxPixelSize)
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

    func testStoreGenerationChangeAloneStillHitsTheCachedPreview() {
        let lock = NSLock()
        var loadCount = 0
        let cache = ClipPreviewCache(loader: { request in
            lock.lock(); loadCount += 1; lock.unlock()
            return .success(self.asset(request.record.byteSize), cost: 64)
        })
        let id = UUID()
        let first = record(7, id: id, generation: 1)
        // Same record, same digest, later store generation: an unrelated history
        // mutation must not throw away pixels that are still correct.
        let later = ClipPreviewRequest(record: first.record, generation: 99)
        XCTAssertEqual(first.identity, later.identity)

        let loaded = expectation(description: "first decode")
        let firstToken = cache.request(first) { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 1)
        withExtendedLifetime(firstToken) {}

        let reused = expectation(description: "cache hit after generation bump")
        let secondToken = cache.request(later) { _ in reused.fulfill() }
        wait(for: [reused], timeout: 1)
        withExtendedLifetime(secondToken) {}

        lock.lock(); let actualLoads = loadCount; lock.unlock()
        XCTAssertEqual(actualLoads, 1, "a generation bump alone must not invalidate the entry")
        XCTAssertEqual(cache.stats.entryCount, 1)
    }

    func testThumbnailArrivalAndPixelBucketAreSeparateCacheIdentities() {
        let id = UUID()
        let base = record(11, id: id).record
        var withoutThumbnail = base
        withoutThumbnail.hasThumbnail = false
        XCTAssertNotEqual(
            ClipPreviewRequest(record: base, generation: 1).identity,
            ClipPreviewRequest(record: withoutThumbnail, generation: 1).identity
        )
        XCTAssertNotEqual(
            ClipPreviewRequest(record: base, generation: 1).identity,
            ClipPreviewRequest(record: base, generation: 1, maxPixelSize: 96).identity
        )
        XCTAssertEqual(
            ClipPreviewRequest(record: base, generation: 1).identity,
            ClipPreviewRequest(record: base, generation: 1, maxPixelSize: 720).identity
        )
    }

    func testThumbnailDecodeHonoursThePixelBucketAndChargesTheRealBitmap() throws {
        let data = try png720()
        let full = try XCTUnwrap(
            ClipPreviewCache.decodedThumbnail(data, maxPixelSize: 720)
        )
        XCTAssertEqual(Int(full.image.size.width), 720)
        // Charged by the bitmap's real stride, which is at least four bytes per pixel
        // and may be padded up by ImageIO's row alignment.
        XCTAssertGreaterThanOrEqual(full.cost, 720 * 720 * 4)
        XCTAssertLessThan(full.cost, 720 * 720 * 8)

        let row = try XCTUnwrap(ClipPreviewCache.decodedThumbnail(data, maxPixelSize: 96))
        XCTAssertLessThanOrEqual(Int(row.image.size.width), 96)
        XCTAssertLessThanOrEqual(Int(row.image.size.height), 96)
        XCTAssertLessThan(row.cost, full.cost / 16)
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
                // `.unknown`, not `.unreachable`: the loader never stats these URLs, so
                // it cannot know they are off-volume — and must not say so.
                guard case .ready(let asset) = result,
                      asset.files.count == 1,
                      asset.files[0].availability == .unknown,
                      asset.files[0].unavailable == false,
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
    // MARK: - File availability badges

    /// The regression this pins: the loader used to report `unavailable: true` for every
    /// row because it does not stat, so an ordinary local file's preview card read
    /// 「网络卷」. "Not measured" now has its own state and claims nothing.
    func testLocalFilePreviewIsNotLabelledAsBeingOnANetworkVolume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-preview-local-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let local = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: local)

        let store = makeStore(at: root.appendingPathComponent("store", isDirectory: true))
        let record = store.insert(fileInsertion(0, url: local))
        store.waitForPendingWrites()

        let cache = ClipPreviewCache(
            configuration: .init(
                maxCost: 8 * 1_024 * 1_024, maxCount: 8, workerCount: 2,
                loadTimeout: 1, negativeTTL: 0.1
            ),
            loader: ClipPreviewCache.loader(store: store)
        )
        let ready = expectation(description: "local file preview")
        var entries: [ClipFilePreviewEntry] = []
        let token = cache.request(ClipPreviewRequest(record: record, generation: 1)) { result in
            guard case .ready(let asset) = result else { return }
            entries = asset.files
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
        withExtendedLifetime(token) {}

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.name, "notes.txt")
        XCTAssertEqual(entry.availability, .unknown)
        XCTAssertFalse(entry.missing)
        XCTAssertFalse(entry.unavailable, "an unmeasured file is not a confirmed off-volume one")
        XCTAssertNil(
            entry.badge,
            "a local file must carry no badge at all — 「网络卷」 least of all"
        )
    }

    /// The three badges the preview card can draw, decided on the entry so the rule is
    /// asserted without standing a SwiftUI tree up.
    func testFileBadgeOnlyClaimsNetworkVolumeWhenItIsConfirmed() {
        func entry(
            missing: Bool, availability: ClipFileAvailability, byteSize: Int64?
        ) -> ClipFilePreviewEntry {
            ClipFilePreviewEntry(
                id: 0, name: "a.txt", directory: "/tmp", icon: NSImage(size: .init(width: 1, height: 1)),
                missing: missing, availability: availability, byteSize: byteSize
            )
        }

        XCTAssertNil(entry(missing: false, availability: .unknown, byteSize: nil).badge)
        XCTAssertNil(entry(missing: false, availability: .local, byteSize: nil).badge)
        XCTAssertEqual(
            entry(missing: false, availability: .local, byteSize: 1_024).badge, .size(1_024)
        )
        XCTAssertEqual(
            entry(missing: false, availability: .unreachable, byteSize: nil).badge, .unreachable
        )
        // `missing` outranks everything, exactly as the view's old if-chain did.
        XCTAssertEqual(
            entry(missing: true, availability: .unreachable, byteSize: 1_024).badge, .missing
        )
        // An unmeasured row never reaches the 「网络卷」 branch, whatever its size.
        XCTAssertEqual(
            entry(missing: false, availability: .unknown, byteSize: 99).badge, .size(99)
        )
    }

    /// The cached formatter must produce exactly what the per-call class method did.
    func testSharedByteFormatterMatchesTheClassMethodItReplaced() {
        for bytes in [0, 1, 999, 1_000, 1_024, 1_048_576, 5_368_709_120] as [Int64] {
            XCTAssertEqual(
                ClipByteSize.string(bytes),
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                "\(bytes) formatted differently once the formatter was reused"
            )
        }
    }

    func testPromisedButUnwrittenThumbnailIsNotPinnedByTheNegativeCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-preview-transient-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)
        let thumbnail = try png720()
        let stored = store.insert(imageInsertion(1, thumbnail: thumbnail))
        store.waitForPendingWrites()

        // A record that claims a thumbnail whose sidecar does not exist: exactly the
        // window between the record committing and its bytes reaching disk.
        let pending = ClipRecord(
            id: UUID(), createdAt: Date(), kind: .image, preview: "not written yet",
            digest: "pending-digest", byteSize: 1, sourceBundleID: nil, sourceName: nil,
            pinned: false, oversized: false, hasThumbnail: true
        )
        let lock = NSLock()
        var loads = 0
        let cache = ClipPreviewCache(
            configuration: .init(
                maxCost: 4 * 1_024 * 1_024, maxCount: 16, workerCount: 2,
                loadTimeout: 1, negativeTTL: 2
            ),
            loader: { request in
                lock.lock(); loads += 1; lock.unlock()
                return ClipPreviewCache.loader(store: store)(request)
            }
        )

        func requestOnce(_ record: ClipRecord) -> ClipPreviewResult? {
            var outcome: ClipPreviewResult?
            let done = expectation(description: "preview for \(record.preview)")
            let token = cache.request(ClipPreviewRequest(record: record, generation: 1)) {
                outcome = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
            withExtendedLifetime(token) {}
            return outcome
        }

        guard case .unavailable(.missing)? = requestOnce(pending) else {
            return XCTFail("a missing sidecar must report as unavailable")
        }
        // Immediately again: the short verdict still absorbs a viewport-sized burst.
        _ = requestOnce(pending)
        lock.lock(); let burstLoads = loads; lock.unlock()
        XCTAssertEqual(burstLoads, 1, "a burst of identical rows must not decode repeatedly")

        // Past the transient ceiling — and well inside the 2s ordinary negative TTL,
        // which is what used to pin a blank tile for a record that is now readable.
        RunLoop.main.run(
            until: Date().addingTimeInterval(ClipPreviewCache.transientNegativeTTL + 0.1)
        )
        _ = requestOnce(pending)
        lock.lock(); let retriedLoads = loads; lock.unlock()
        XCTAssertEqual(retriedLoads, 2, "the transient verdict must expire well before 2s")

        // An ordinary failure keeps the full negative TTL: a record with no thumbnail at
        // all is a verdict, not a race.
        let hopeless = ClipRecord(
            id: UUID(), createdAt: Date(), kind: .image, preview: "no thumbnail",
            digest: "hopeless-digest", byteSize: 1, sourceBundleID: nil, sourceName: nil,
            pinned: false, oversized: false, hasThumbnail: false
        )
        _ = requestOnce(hopeless)
        lock.lock(); let firstHopeless = loads; lock.unlock()
        RunLoop.main.run(
            until: Date().addingTimeInterval(ClipPreviewCache.transientNegativeTTL + 0.1)
        )
        _ = requestOnce(hopeless)
        lock.lock(); let secondHopeless = loads; lock.unlock()
        XCTAssertEqual(
            secondHopeless, firstHopeless,
            "a record with no thumbnail must stay negatively cached for the full TTL"
        )

        // And the record that really is on disk is unaffected throughout.
        guard case .ready(let asset)? = requestOnce(stored), asset.image != nil else {
            return XCTFail("a stored thumbnail must still decode")
        }
    }

    /// Bytes that are present but will not decode are a permanent verdict, not a race, and
    /// must not borrow the short transient TTL — otherwise a single corrupt sidecar makes a
    /// visible row re-read and re-decode five times a second for as long as it is on screen.
    func testACorruptThumbnailIsNegativelyCachedForTheFullTTLNotRetriedFiveTimesASecond() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-preview-corrupt-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        // A truncated PNG: a real header, no image data. This is what a write interrupted
        // partway through leaves behind, and it will never become decodable.
        let truncated = try png720().prefix(64)
        let corrupt = store.insert(imageInsertion(7, thumbnail: Data(truncated)))
        let pending = ClipRecord(
            id: UUID(), createdAt: Date(), kind: .image, preview: "not written yet",
            digest: "pending-digest", byteSize: 1, sourceBundleID: nil, sourceName: nil,
            pinned: false, oversized: false, hasThumbnail: true
        )
        store.waitForPendingWrites()
        XCTAssertTrue(corrupt.hasThumbnail, "the record must still promise a thumbnail")

        let lock = NSLock()
        var loads = 0
        let cache = ClipPreviewCache(
            configuration: .init(
                maxCost: 4 * 1_024 * 1_024, maxCount: 16, workerCount: 2,
                loadTimeout: 1, negativeTTL: 2
            ),
            loader: { request in
                lock.lock(); loads += 1; lock.unlock()
                return ClipPreviewCache.loader(store: store)(request)
            }
        )

        func requestOnce(_ record: ClipRecord) -> ClipPreviewResult? {
            var outcome: ClipPreviewResult?
            let done = expectation(description: "preview for \(record.preview)")
            let token = cache.request(ClipPreviewRequest(record: record, generation: 1)) {
                outcome = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
            withExtendedLifetime(token) {}
            return outcome
        }

        guard case .unavailable(.unsupported)? = requestOnce(corrupt) else {
            return XCTFail("undecodable bytes must report as unsupported, not missing")
        }
        lock.lock(); let afterFirst = loads; lock.unlock()

        // Well past the transient ceiling and still inside the ordinary negative TTL.
        RunLoop.main.run(
            until: Date().addingTimeInterval(ClipPreviewCache.transientNegativeTTL + 0.3)
        )
        _ = requestOnce(corrupt)
        lock.lock(); let afterSecond = loads; lock.unlock()
        XCTAssertEqual(
            afterSecond, afterFirst,
            "a corrupt sidecar must be decoded once, not once per transient window"
        )

        // The genuinely transient case, over the same interval, still retries — the two
        // verdicts have to stay distinguishable, not merely both be cached.
        _ = requestOnce(pending)
        lock.lock(); let afterPending = loads; lock.unlock()
        RunLoop.main.run(
            until: Date().addingTimeInterval(ClipPreviewCache.transientNegativeTTL + 0.1)
        )
        _ = requestOnce(pending)
        lock.lock(); let afterPendingRetry = loads; lock.unlock()
        XCTAssertEqual(
            afterPendingRetry, afterPending + 1,
            "an unwritten sidecar must still be retried once the short verdict expires"
        )
    }
}
