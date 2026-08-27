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

/// Exact identity of pixels/metadata shown by a reusable SwiftUI row. A store generation
/// is included even when the record UUID survives an edit, and the digest protects the
/// inverse case where a caller hands the cache a stale generation snapshot.
struct ClipPreviewIdentity: Hashable {
    let id: UUID
    let digest: String
    let generation: UInt64
    let kind: ClipKind
}

struct ClipPreviewRequest {
    let record: ClipRecord
    let generation: UInt64

    var identity: ClipPreviewIdentity {
        ClipPreviewIdentity(
            id: record.id, digest: record.digest, generation: generation, kind: record.kind
        )
    }
}

struct ClipFilePreviewEntry: Identifiable {
    let id: Int
    let name: String
    let directory: String
    let icon: NSImage
    let missing: Bool
    let unavailable: Bool
    let byteSize: Int64?
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
                    guard record.hasThumbnail,
                          let data = access.thumbnailData(for: record),
                          let decoded = forceDecoded(data)
                    else { return .failure(.missing) }
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
                unavailable: true,
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

    private static func forceDecoded(_ data: Data) -> (image: NSImage, cost: Int)? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let source = CGImageSourceCreateImageAtIndex(
                imageSource, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { return nil }
        let width = max(1, source.width)
        let height = max(1, source.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let decoded = context.makeImage() else { return nil }
        return (
            NSImage(cgImage: decoded, size: NSSize(width: width, height: height)),
            max(1, context.bytesPerRow * height)
        )
    }
}
