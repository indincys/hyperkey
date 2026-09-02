import AppKit
import Foundation
import UniformTypeIdentifiers

/// The two store reads used by preview workers are explicitly documented thread-safe
/// by `ClipStore`. Keeping that narrow capability in a Sendable box prevents the worker
/// from accidentally reaching any of the store's main-thread mutation surface.
struct ClipPreviewStoreAccess: @unchecked Sendable {
    private let store: ClipStore

    init(store: ClipStore) { self.store = store }

    func payloadData(for id: UUID) -> Data? { store.payloadData(for: id) }
    func thumbnailData(for record: ClipRecord) -> Data? { store.thumbnailData(for: record) }
}

final class ClipPreviewWeakBox<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}

/// Exact identity of pixels/metadata shown by a reusable SwiftUI row.
///
/// The store's generation is deliberately *not* part of this key. It advances on every
/// history mutation, so including it threw away every decoded pixel in the cache each
/// time an unrelated row was pinned, deleted or captured. What the key actually has to
/// describe is the bytes a row draws: the record identity, the content digest (which
/// changes whenever the payload is rewritten), whether a sidecar thumbnail exists at all
/// (the one image-preview input that can be rewritten under an unchanged digest), the
/// kind, and the pixel bucket the decode was sized for.
struct ClipPreviewIdentity: Hashable {
    let id: UUID
    let digest: String
    let kind: ClipKind
    /// A thumbnail can be written after the record was first stored, under the same
    /// digest. Keying on its presence retires the "no pixels yet" entry when it lands.
    let hasThumbnail: Bool
    /// Pixel bucket the cached bitmap was decoded into, so a row-sized and a
    /// pane-sized preview of the same record are separate entries rather than one
    /// stealing the other's pixels.
    let maxPixelSize: Int
}

struct ClipPreviewRequest {
    /// Default ceiling: the sidecar thumbnails `ClipStore` writes are already capped at
    /// 720px, so this reproduces the previous full-thumbnail decode exactly.
    static let defaultMaxPixelSize = 720

    let record: ClipRecord
    /// Retained for callers that still hand over a store generation. It no longer takes
    /// part in the cache key — see `ClipPreviewIdentity`.
    let generation: UInt64
    /// Longest edge the decode should produce. `nil` keeps the 720px default.
    let maxPixelSize: Int?

    init(record: ClipRecord, generation: UInt64, maxPixelSize: Int? = nil) {
        self.record = record
        self.generation = generation
        self.maxPixelSize = maxPixelSize
    }

    var resolvedMaxPixelSize: Int {
        max(1, maxPixelSize ?? Self.defaultMaxPixelSize)
    }

    var identity: ClipPreviewIdentity {
        ClipPreviewIdentity(
            id: record.id, digest: record.digest, kind: record.kind,
            hasThumbnail: record.hasThumbnail, maxPixelSize: resolvedMaxPixelSize
        )
    }
}

/// What is actually known about a file URL's locality.
///
/// Three states rather than a boolean because "not reachable" and "never looked" are
/// different answers, and the production loader only ever gives the second one: it
/// deliberately never stats a pasteboard URL (see `loadFiles`). Collapsing the two is
/// what made every ordinary local file wear a 「网络卷」 badge.
enum ClipFileAvailability: Equatable {
    /// Nothing was measured. The row says nothing about where the file lives.
    case unknown
    /// Confirmed present on a local volume.
    case local
    /// Confirmed to be behind a mount that did not answer.
    case unreachable
}

/// What the preview card shows beside a file name, decided here rather than in the view
/// so the rule — `.unknown` claims nothing — has one definition and can be asserted
/// without standing a SwiftUI tree up.
enum ClipFileBadge: Equatable {
    case missing
    case unreachable
    case size(Int64)
}

struct ClipFilePreviewEntry: Identifiable {
    let id: Int
    let name: String
    let directory: String
    let icon: NSImage
    let missing: Bool
    let availability: ClipFileAvailability
    let byteSize: Int64?

    /// Kept for callers that only ever asked "is this off-volume?". Only a *confirmed*
    /// unreachable file answers yes; an unmeasured one is not evidence of anything.
    var unavailable: Bool { availability == .unreachable }

    var badge: ClipFileBadge? {
        if missing { return .missing }
        if availability == .unreachable { return .unreachable }
        if let byteSize { return .size(byteSize) }
        return nil
    }
}

struct ClipPreviewAsset {
    let image: NSImage?
    let files: [ClipFilePreviewEntry]
    let overflowFileCount: Int
}

enum ClipPreviewFailure: Equatable {
    case missing
    case timedOut
    case unsupported
    case unavailable

    var message: String {
        switch self {
        case .missing: return "预览文件已不存在"
        case .timedOut: return "预览读取超时"
        case .unsupported: return "此格式没有可用预览"
        case .unavailable: return "暂时无法生成预览"
        }
    }
}

enum ClipPreviewResult {
    case ready(ClipPreviewAsset)
    case unavailable(ClipPreviewFailure)
}

enum ClipVisualState {
    case idle
    case loading
    case ready(ClipPreviewAsset)
    case unavailable(ClipPreviewFailure)
}

enum ClipPreviewLoaderResult {
    case success(ClipPreviewAsset, cost: Int)
    case failure(ClipPreviewFailure)
    /// A failure the loader expects to resolve on its own within moments — a record whose
    /// sidecar thumbnail has not finished being written yet. The row does not retry by
    /// itself, so pinning this behind the ordinary negative TTL would leave a permanent
    /// blank tile for an image that is on disk a few milliseconds later.
    case transientFailure(ClipPreviewFailure)
}

/// Cancellation is subscriber-scoped: cancelling one reused row never cancels another
/// visible row waiting on the same underlying decode.
fileprivate final class ClipPreviewCancellationState {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

final class ClipPreviewRequestToken {
    private let lock = NSLock()
    private let state: ClipPreviewCancellationState
    private var cancellation: (() -> Void)?

    fileprivate init(
        state: ClipPreviewCancellationState, cancellation: @escaping () -> Void
    ) {
        self.state = state
        self.cancellation = cancellation
    }

    func cancel() {
        state.cancel()
        lock.lock()
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    deinit { cancel() }
}

/// A bounded, asynchronous preview pipeline. Its state queue owns the LRU and in-flight
/// maps; expensive work has a small concurrent pool, so callers never perform disk I/O,
/// image decode, Quick Look, or file metadata reads synchronously.
final class ClipPreviewCache: @unchecked Sendable {
    private static let auxiliaryWorkers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.indincys.hyper.clip-preview-cache.auxiliary"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func performBackground(_ work: @escaping @Sendable () -> Void) {
        auxiliaryWorkers.addOperation(work)
    }

    struct Configuration {
        var maxCost: Int
        var maxCount: Int
        var workerCount: Int
        var loadTimeout: TimeInterval
        var negativeTTL: TimeInterval

        init(
            maxCost: Int = 32 * 1_024 * 1_024,
            maxCount: Int = 96,
            workerCount: Int = 4,
            loadTimeout: TimeInterval = 0.45,
            negativeTTL: TimeInterval = 2
        ) {
            self.maxCost = max(1, maxCost)
            self.maxCount = max(1, maxCount)
            self.workerCount = min(max(1, workerCount), 8)
            self.loadTimeout = max(0.01, loadTimeout)
            self.negativeTTL = max(0.01, negativeTTL)
        }
    }

    /// Ceiling on how long a "not written yet" answer is remembered.
    static let transientNegativeTTL: TimeInterval = 0.2

    struct Stats {
        let currentCost: Int
        let entryCount: Int
        let inFlightCount: Int
    }

    typealias Loader = (ClipPreviewRequest) -> ClipPreviewLoaderResult
    typealias Completion = (ClipPreviewResult) -> Void

    private final class Entry {
        let key: ClipPreviewIdentity
        var result: ClipPreviewResult
        var cost: Int
        var expiresAt: Date?
        weak var previous: Entry?
        var next: Entry?

        init(
            key: ClipPreviewIdentity, result: ClipPreviewResult, cost: Int, expiresAt: Date?
        ) {
            self.key = key
            self.result = result
            self.cost = cost
            self.expiresAt = expiresAt
        }
    }

    private struct InFlight {
        let jobID: UUID
        let operation: Operation
        var subscribers: [UUID: Completion]
    }

    private let configuration: Configuration
    private let loader: Loader
    private let stateQueue = DispatchQueue(label: "com.indincys.hyper.clip-preview-cache.state")
    private let workers: OperationQueue
    private var entries: [ClipPreviewIdentity: Entry] = [:]
    private var head: Entry?
    private var tail: Entry?
    private var currentCost = 0
    private var inFlight: [ClipPreviewIdentity: InFlight] = [:]
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var purgeHandler: (() -> Void)?

    init(configuration: Configuration = Configuration(), loader: @escaping Loader) {
        self.configuration = configuration
        self.loader = loader
        let workers = OperationQueue()
        workers.name = "com.indincys.hyper.clip-preview-cache.work"
        workers.qualityOfService = .userInitiated
        workers.maxConcurrentOperationCount = configuration.workerCount
        self.workers = workers

        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: stateQueue
        )
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let self, let pressure else { return }
            self.cancelAllInFlight()
            if pressure.data.contains(.critical) {
                self.removeAllEntries()
            } else {
                self.trim(
                    maxCost: max(1, self.configuration.maxCost / 4),
                    maxCount: max(1, self.configuration.maxCount / 4)
                )
            }
            self.notifyPurge()
        }
        pressure.resume()
        memoryPressureSource = pressure
    }

    deinit {
        memoryPressureSource?.cancel()
        workers.cancelAllOperations()
    }

    @discardableResult
    func request(
        _ request: ClipPreviewRequest, completion: @escaping Completion
    ) -> ClipPreviewRequestToken {
        let subscriberID = UUID()
        let key = request.identity
        let cancellationState = ClipPreviewCancellationState()
        let guardedCompletion: Completion = { [weak cancellationState] result in
            guard cancellationState?.isCancelled == false else { return }
            completion(result)
        }
        stateQueue.async { [weak self] in
            self?.startOrJoin(
                request, subscriberID: subscriberID, completion: guardedCompletion
            )
        }
        return ClipPreviewRequestToken(
            state: cancellationState,
            cancellation: { [weak self] in
                self?.stateQueue.async { self?.cancel(key: key, subscriberID: subscriberID) }
            }
        )
    }

    var stats: Stats {
        stateQueue.sync {
            Stats(
                currentCost: currentCost,
                entryCount: entries.count,
                inFlightCount: inFlight.count
            )
        }
    }

    /// A hidden panel retains no decoded pixels and owns no background jobs. Reopening
    /// repopulates only the newly visible viewport.
    func handlePanelClosed() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.cancelAllInFlight()
            self.removeAllEntries()
        }
    }

    func removeAll() {
        stateQueue.async { [weak self] in self?.removeAllEntries() }
    }

    func setPurgeHandler(_ handler: @escaping () -> Void) {
        stateQueue.async { [weak self] in self?.purgeHandler = handler }
    }

    private func startOrJoin(
        _ request: ClipPreviewRequest,
        subscriberID: UUID,
        completion: @escaping Completion
    ) {
        let key = request.identity
        if let cached = entries[key] {
            if let expiry = cached.expiresAt, expiry <= Date() {
                remove(cached)
            } else {
                touch(cached)
                deliver(cached.result, to: [completion])
                return
            }
        }
        if var job = inFlight[key] {
            job.subscribers[subscriberID] = completion
            inFlight[key] = job
            return
        }

        let jobID = UUID()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, operation?.isCancelled != true else { return }
            let loaded = self.loader(request)
            self.stateQueue.async { [weak self] in
                self?.finish(key: key, jobID: jobID, loaded: loaded)
            }
        }
        inFlight[key] = InFlight(
            jobID: jobID, operation: operation, subscribers: [subscriberID: completion]
        )
        workers.addOperation(operation)
        stateQueue.asyncAfter(deadline: .now() + configuration.loadTimeout) { [weak self] in
            self?.timeOut(key: key, jobID: jobID)
        }
    }

    private func cancel(key: ClipPreviewIdentity, subscriberID: UUID) {
        guard var job = inFlight[key] else { return }
        job.subscribers.removeValue(forKey: subscriberID)
        guard job.subscribers.isEmpty else {
            inFlight[key] = job
            return
        }
        job.operation.cancel()
        inFlight.removeValue(forKey: key)
    }

    private func finish(
        key: ClipPreviewIdentity, jobID: UUID, loaded: ClipPreviewLoaderResult
    ) {
        guard let job = inFlight[key], job.jobID == jobID else { return }
        inFlight.removeValue(forKey: key)
        let result: ClipPreviewResult
        switch loaded {
        case .success(let asset, let rawCost):
            result = .ready(asset)
            let cost = max(1, rawCost)
            if cost <= configuration.maxCost {
                insert(key: key, result: result, cost: cost, expiresAt: nil)
            }
        case .failure(let failure):
            result = .unavailable(failure)
            insert(
                key: key, result: result, cost: 1,
                expiresAt: Date().addingTimeInterval(configuration.negativeTTL)
            )
        case .transientFailure(let failure):
            result = .unavailable(failure)
            // Still cached, so a viewport full of the same not-yet-written record cannot
            // start one decode per frame — but only for long enough to absorb that burst.
            insert(
                key: key, result: result, cost: 1,
                expiresAt: Date().addingTimeInterval(
                    min(configuration.negativeTTL, Self.transientNegativeTTL)
                )
            )
        }
        deliver(result, to: Array(job.subscribers.values))
    }

    private func timeOut(key: ClipPreviewIdentity, jobID: UUID) {
        guard let job = inFlight[key], job.jobID == jobID else { return }
        inFlight.removeValue(forKey: key)
        job.operation.cancel()
        let result = ClipPreviewResult.unavailable(ClipPreviewFailure.timedOut)
        insert(
            key: key, result: result, cost: 1,
            expiresAt: Date().addingTimeInterval(configuration.negativeTTL)
        )
        deliver(result, to: Array(job.subscribers.values))
    }

    private func deliver(_ result: ClipPreviewResult, to callbacks: [Completion]) {
        guard !callbacks.isEmpty else { return }
        DispatchQueue.main.async {
            for callback in callbacks { callback(result) }
        }
    }

    private func insert(
        key: ClipPreviewIdentity, result: ClipPreviewResult, cost: Int, expiresAt: Date?
    ) {
        if let existing = entries[key] { remove(existing) }
        let entry = Entry(key: key, result: result, cost: cost, expiresAt: expiresAt)
        entries[key] = entry
        entry.next = head
        head?.previous = entry
        head = entry
        if tail == nil { tail = entry }
        currentCost += cost
        trim(maxCost: configuration.maxCost, maxCount: configuration.maxCount)
    }

    private func touch(_ entry: Entry) {
        guard head !== entry else { return }
        unlink(entry)
        entry.previous = nil
        entry.next = head
        head?.previous = entry
        head = entry
        if tail == nil { tail = entry }
    }

    private func trim(maxCost: Int, maxCount: Int) {
        while (currentCost > maxCost || entries.count > maxCount), let oldest = tail {
            remove(oldest)
        }
    }

    private func remove(_ entry: Entry) {
        entries.removeValue(forKey: entry.key)
        currentCost -= entry.cost
        unlink(entry)
    }

    private func unlink(_ entry: Entry) {
        if let previous = entry.previous {
            previous.next = entry.next
        } else if head === entry {
            head = entry.next
        }
        if let next = entry.next {
            next.previous = entry.previous
        } else if tail === entry {
            tail = entry.previous
        }
        entry.previous = nil
        entry.next = nil
    }

    private func removeAllEntries() {
        entries.removeAll()
        head = nil
        tail = nil
        currentCost = 0
    }

    private func cancelAllInFlight() {
        for job in inFlight.values { job.operation.cancel() }
        inFlight.removeAll()
    }

    private func notifyPurge() {
        guard let purgeHandler else { return }
        DispatchQueue.main.async(execute: purgeHandler)
    }
}

// MARK: - Production loader

extension ClipPreviewCache {
    static func loader(store: ClipStore) -> Loader {
        let access = ClipPreviewStoreAccess(store: store)
        return { request in
            autoreleasepool {
                guard !Thread.isMainThread else { return .failure(.unavailable) }
                let record = request.record
                guard !record.oversized else { return .failure(.unsupported) }
                switch record.kind {
                case .image:
                    // `hasThumbnail` is set when the record commits; the sidecar file is
                    // written just after. An absent file is a race with that write, not a
                    // verdict about the record, so it is only briefly negative-cached.
                    guard record.hasThumbnail else { return .failure(.missing) }
                    guard let data = access.thumbnailData(for: record) else {
                        return .transientFailure(.missing)
                    }
                    // Bytes that exist but will not decode are truncated or corrupt. That
                    // does not heal on its own, so it takes the full negative TTL: retrying
                    // a doomed ImageIO decode five times a second for a visible row is how
                    // a permanent failure turns into a permanent cost.
                    guard let decoded = decodedThumbnail(
                        data, maxPixelSize: request.resolvedMaxPixelSize
                    ) else { return .failure(.unsupported) }
                    return .success(
                        ClipPreviewAsset(image: decoded.image, files: [], overflowFileCount: 0),
                        cost: decoded.cost
                    )
                case .files:
                    guard let data = access.payloadData(for: record.id),
                          let payload = ClipPayloadCoder.decode(data)
                    else { return .failure(.missing) }
                    let urls = ClipCapture.fileURLs(from: payload)
                    guard !urls.isEmpty else { return .failure(.unsupported) }
                    return loadFiles(urls)
                default:
                    return .failure(.unsupported)
                }
            }
        }
    }

    private static let maximumFileRows = 24

    private static func loadFiles(_ urls: [URL]) -> ClipPreviewLoaderResult {
        let limited = Array(urls.prefix(maximumFileRows))
        var rows: [ClipFilePreviewEntry] = []
        rows.reserveCapacity(limited.count)
        var cost = 0

        for (index, url) in limited.enumerated() {
            // A pasteboard file URL carries no trustworthy locality or non-symlink
            // provenance. Do not discover those properties here: fileExists, stat,
            // resource values and icon(forFile:) can all follow an offline mount or a
            // symlink and permanently occupy one of the four preview workers. Names,
            // directories and generic type icons are derived from URL bytes/extension
            // only, so network homes, CloudStorage, FileProvider and missing paths all
            // reach the same prompt placeholder without touching their filesystem.
            let type = UTType(filenameExtension: url.pathExtension) ?? .item
            let icon = (NSWorkspace.shared.icon(for: type).copy() as? NSImage)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            icon.size = NSSize(width: 32, height: 32)
            cost += 32 * 32 * 4
            rows.append(ClipFilePreviewEntry(
                id: index,
                name: url.lastPathComponent,
                directory: url.deletingLastPathComponent().path,
                icon: icon,
                missing: false,
                // Nothing above measured anything, so the honest answer is "unknown".
                // Reporting `.unreachable` here would badge every local file 「网络卷」.
                availability: .unknown,
                byteSize: nil
            ))
        }

        return .success(
            ClipPreviewAsset(
                image: nil,
                files: rows,
                overflowFileCount: max(0, urls.count - limited.count)
            ),
            cost: max(1, cost)
        )
    }

    /// One ImageIO step to the size actually drawn.
    ///
    /// This used to decode the full-size image and then redraw it into a second bitmap
    /// context of the same dimensions purely to force the pixels resident — two full
    /// buffers and a resample for one visible image. `CGImageSourceCreateThumbnailAtIndex`
    /// decodes straight into the target bucket and returns pixels that are already
    /// materialised, so there is nothing left to force.
    static func decodedThumbnail(
        _ data: Data, maxPixelSize: Int
    ) -> (image: NSImage, cost: Int)? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            // Sidecar thumbnails carry no embedded thumbnail of their own, and an
            // embedded one in a pasted original would be arbitrarily small.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, options as CFDictionary
        ) else { return nil }
        let width = max(1, decoded.width)
        let height = max(1, decoded.height)
        // Charge the bitmap's real stride, as the redraw-based implementation did: a row
        // is padded to an alignment ImageIO chooses, and `width * 4` understates it.
        // Bucketing already makes this smaller than the stored image whenever the caller
        // asked for a row-sized preview.
        return (
            NSImage(cgImage: decoded, size: NSSize(width: width, height: height)),
            max(1, decoded.bytesPerRow * height)
        )
    }
}
