import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

/// Converts one external drop into one all-or-nothing clipboard entry.
enum ClipDropIntake {
    private static let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.drop")

    static let acceptedTypes: [UTType] = [
        .fileURL, .png, .jpeg, .heic, .gif, .tiff, .url, .utf8PlainText, .plainText,
    ]
    static let sourceName = "拖入"

    struct Limits: Equatable {
        var maximumProviderCount: Int
        var maximumConcurrentLoads: Int
        var maximumItemBytes: Int
        var maximumTotalBytes: Int
        var maximumFileURLBytes: Int
        var timeout: TimeInterval

        init(
            maximumProviderCount: Int = 128,
            maximumConcurrentLoads: Int = 8,
            maximumItemBytes: Int = 20 * 1024 * 1024,
            maximumTotalBytes: Int = 64 * 1024 * 1024,
            maximumFileURLBytes: Int = 64 * 1024,
            timeout: TimeInterval = 5
        ) {
            self.maximumProviderCount = maximumProviderCount
            self.maximumConcurrentLoads = maximumConcurrentLoads
            self.maximumItemBytes = maximumItemBytes
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumFileURLBytes = maximumFileURLBytes
            self.timeout = timeout
        }

        static let standard = Limits()

        fileprivate var isValid: Bool {
            maximumProviderCount > 0 && maximumConcurrentLoads > 0
                && maximumItemBytes > 0 && maximumTotalBytes > 0
                && maximumFileURLBytes > 0 && timeout > 0
        }
    }

    static func isOwnDrag(_ info: DropInfo) -> Bool {
        info.itemProviders(for: acceptedTypes).contains {
            $0.registeredTypeIdentifiers.contains(ClipDragItem.privateTypeIdentifier)
        }
    }

    typealias Completion = (ClipPayload?, ClipKind?) -> Void

    /// Uses the live drag pasteboard only as a synchronous description of the complete
    /// session. The returned `DropInfo` providers remain the owners of all asynchronous
    /// reads: retaining `NSPasteboardItem` here would race the drag pasteboard being
    /// cleared or reused as soon as `performDrop` returns.
    static func preflightCompleteSession(
        pasteboard: NSPasteboard, nativeProviders: [NSItemProvider],
        limits: Limits = .standard
    ) -> Bool {
        guard limits.isValid,
              let items = pasteboard.pasteboardItems,
              !items.isEmpty,
              items.count == nativeProviders.count,
              items.count <= limits.maximumProviderCount
        else { return false }

        let advertisedFamilies = items.compactMap { item in
            family(forTypeIdentifiers: item.types.map(\.rawValue))
        }
        guard advertisedFamilies.count == items.count,
              let family = advertisedFamilies.first,
              advertisedFamilies.allSatisfy({ $0 == family })
        else { return false }

        let nativePlans = nativeProviders.enumerated().compactMap { index, provider in
            loadPlan(for: provider, index: index)
        }
        guard nativePlans.count == nativeProviders.count else { return false }
        return zip(advertisedFamilies, nativePlans).allSatisfy { advertised, native in
            advertised == native.family
        }
    }

    static func read(_ providers: [NSItemProvider], completion: @escaping Completion) {
        read(providers, limits: .standard, completion: completion)
    }

    /// Every provider must describe the same supported content family. Classification is
    /// completed before the first byte is requested, so a mixed or unsupported drag can
    /// never be silently filtered down to the subset Hyper happened to understand.
    static func read(
        _ providers: [NSItemProvider],
        limits: Limits,
        completion: @escaping Completion
    ) {
        guard limits.isValid, !providers.isEmpty,
              providers.count <= limits.maximumProviderCount
        else {
            fail(completion)
            return
        }

        var plans: [LoadPlan] = []
        plans.reserveCapacity(providers.count)
        for (index, provider) in providers.enumerated() {
            guard let plan = loadPlan(for: provider, index: index) else {
                fail(completion)
                return
            }
            plans.append(plan)
        }
        guard let family = plans.first?.family,
              plans.allSatisfy({ $0.family == family })
        else {
            fail(completion)
            return
        }

        ReadCoordinator(
            plans: plans, family: family, limits: limits, completion: completion
        ).start()
    }

    private static func fail(_ completion: @escaping Completion) {
        DispatchQueue.main.async { completion(nil, nil) }
    }

    private enum Family: Equatable {
        case files
        case images
        case text
    }

    private struct LoadPlan {
        let index: Int
        let provider: NSItemProvider
        let family: Family
        let type: String
    }

    private enum LoadedValue {
        case file(URL)
        case image([String: Data])
        case text(String)
    }

    private struct DecodedValue {
        let value: LoadedValue
        let retainedBytes: Int
    }

    private static let imageTypes = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier,
        UTType.gif.identifier, UTType.tiff.identifier,
    ]
    private static let textTypes = [
        UTType.utf8PlainText.identifier, UTType.url.identifier, UTType.plainText.identifier,
    ]

    private static func family(forTypeIdentifiers identifiers: [String]) -> Family? {
        func contains(_ expected: UTType) -> Bool {
            identifiers.contains { raw in
                guard let type = UTType(raw) else { return raw == expected.identifier }
                return type == expected || type.conforms(to: expected)
            }
        }
        if contains(.fileURL) { return .files }
        if identifiers.contains(where: { imageTypes.contains($0) })
            || identifiers.contains(where: { raw in
                guard let type = UTType(raw) else { return false }
                return type.conforms(to: .image)
                    && imageTypes.contains(where: { type.conforms(to: UTType($0) ?? .data) })
            }) {
            return .images
        }
        if contains(.utf8PlainText) || contains(.url) || contains(.plainText) { return .text }
        return nil
    }

    private static func loadPlan(for provider: NSItemProvider, index: Int) -> LoadPlan? {
        // Finder images also advertise previews. File URL wins so the original file is
        // retained, not a lossy preview representation.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return LoadPlan(
                index: index, provider: provider, family: .files,
                type: UTType.fileURL.identifier
            )
        }
        if let type = imageTypes.first(where: provider.hasItemConformingToTypeIdentifier) {
            return LoadPlan(index: index, provider: provider, family: .images, type: type)
        }
        if let type = textTypes.first(where: provider.hasItemConformingToTypeIdentifier) {
            return LoadPlan(index: index, provider: provider, family: .text, type: type)
        }
        return nil
    }

    private final class ReadCoordinator {
        private let plans: [LoadPlan]
        private let family: Family
        private let limits: Limits
        private let completion: Completion
        private let lock = NSLock()

        private var slots: [LoadedValue?]
        private var nextPlan = 0
        private var activeCount = 0
        private var completedIndices = Set<Int>()
        private var progresses: [Int: Progress] = [:]
        private var totalBytes = 0
        private var finished = false

        init(plans: [LoadPlan], family: Family, limits: Limits, completion: @escaping Completion) {
            self.plans = plans
            self.family = family
            self.limits = limits
            self.completion = completion
            slots = Array(repeating: nil, count: plans.count)
        }

        func start() {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limits.timeout) {
                [self] in
                finishFailure(reason: "drop provider deadline exceeded")
            }
            pump()
        }

        private func pump() {
            var launches: [LoadPlan] = []
            lock.lock()
            if !finished {
                let concurrency = min(limits.maximumConcurrentLoads, limits.maximumProviderCount)
                while activeCount < concurrency, nextPlan < plans.count {
                    launches.append(plans[nextPlan])
                    nextPlan += 1
                    activeCount += 1
                }
            }
            lock.unlock()

            for plan in launches {
                let progress = plan.provider.loadDataRepresentation(forTypeIdentifier: plan.type) {
                    [self] data, error in
                    receive(data: data, error: error, for: plan)
                }
                track(progress: progress, for: plan.index)
            }
        }

        private func track(progress: Progress, for index: Int) {
            lock.lock()
            if finished || completedIndices.contains(index) {
                lock.unlock()
                progress.cancel()
                return
            }
            progresses[index] = progress
            lock.unlock()
        }

        private func receive(data: Data?, error: Error?, for plan: LoadPlan) {
            guard let data, !data.isEmpty,
                  data.count <= limits.maximumItemBytes,
                  let decoded = Self.decode(data, for: plan, limits: limits),
                  decoded.retainedBytes <= limits.maximumItemBytes
            else {
                finishFailure(
                    reason: "drop item rejected: \(error?.localizedDescription ?? "invalid or oversized data")"
                )
                return
            }

            var shouldPump = false
            var success: (ClipPayload, ClipKind)?
            var cancelled: [Progress] = []
            lock.lock()
            guard !finished, !completedIndices.contains(plan.index) else {
                lock.unlock()
                return
            }
            completedIndices.insert(plan.index)
            progresses.removeValue(forKey: plan.index)
            activeCount -= 1

            guard totalBytes <= limits.maximumTotalBytes - decoded.retainedBytes else {
                finished = true
                cancelled = Array(progresses.values)
                progresses.removeAll()
                lock.unlock()
                cancelled.forEach { $0.cancel() }
                finishCompletion(nil)
                return
            }
            totalBytes += decoded.retainedBytes
            slots[plan.index] = decoded.value

            if completedIndices.count == plans.count {
                finished = true
                success = resultLocked()
            } else {
                shouldPump = true
            }
            lock.unlock()

            if let success { finishCompletion(success) }
            if shouldPump { pump() }
        }

        private static func decode(
            _ data: Data, for plan: LoadPlan, limits: Limits
        ) -> DecodedValue? {
            switch plan.family {
            case .files:
                guard data.count <= limits.maximumFileURLBytes,
                      let string = ClipDropIntake.text(from: data),
                      !string.isEmpty, !string.contains("\0"),
                      string.utf8.count <= limits.maximumFileURLBytes,
                      let url = URL(string: string), url.isFileURL
                else { return nil }
                return DecodedValue(value: .file(url), retainedBytes: data.count)
            case .images:
                guard ClipPasteboardTypePolicy.shouldPreserve(plan.type, data: data) else {
                    return nil
                }
                guard let payload = ClipImageCodec.augmentedPayload(
                    [[plan.type: data]], maximumTotalBytes: limits.maximumItemBytes
                ), let bucket = payload.first else { return nil }
                return DecodedValue(
                    value: .image(bucket),
                    retainedBytes: bucket.values.reduce(0) { $0 + $1.count }
                )
            case .text:
                guard let string = ClipDropIntake.text(from: data),
                      !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return DecodedValue(value: .text(string), retainedBytes: data.count)
            }
        }

        private func resultLocked() -> (ClipPayload, ClipKind)? {
            guard slots.allSatisfy({ $0 != nil }) else { return nil }
            switch family {
            case .files:
                let urls = slots.compactMap { value -> URL? in
                    guard case .file(let url) = value else { return nil }
                    return url
                }
                guard urls.count == slots.count else { return nil }
                return (
                    urls.map { [UTType.fileURL.identifier: Data($0.absoluteString.utf8)] },
                    .files
                )
            case .images:
                let payload = slots.compactMap { value -> [String: Data]? in
                    guard case .image(let bucket) = value else { return nil }
                    return bucket
                }
                guard payload.count == slots.count else { return nil }
                return (payload, .image)
            case .text:
                let strings = slots.compactMap { value -> String? in
                    guard case .text(let text) = value else { return nil }
                    return text
                }
                guard strings.count == slots.count else { return nil }
                let payload = strings.map {
                    [UTType.utf8PlainText.identifier: Data($0.utf8)]
                }
                let kind = strings.count == 1 ? ClipCapture.textKind(for: strings[0]) : .text
                return (payload, kind)
            }
        }

        private func finishFailure(reason: String) {
            var cancelled: [Progress] = []
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            cancelled = Array(progresses.values)
            progresses.removeAll()
            lock.unlock()
            cancelled.forEach { $0.cancel() }
            ClipDropIntake.log.error("\(reason, privacy: .public)")
            finishCompletion(nil)
        }

        private func finishCompletion(_ success: (ClipPayload, ClipKind)?) {
            DispatchQueue.main.async { [completion] in
                if let success {
                    completion(success.0, success.1)
                } else {
                    completion(nil, nil)
                }
            }
        }
    }

    private static func text(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .utf16)
    }
}
