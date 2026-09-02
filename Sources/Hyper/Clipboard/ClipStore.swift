import AppKit
import Darwin
import Foundation
import ImageIO
import os

/// On-disk clipboard history.
///
/// Layout, under `~/.local/share/hyper/clipboard/`:
///
///     index.json        every record's metadata, in newest-first order
///     index.json.backup last completely committed index snapshot
///     data/<uuid>.plist the pasteboard payload for one record
///     thumbs/<uuid>.png a downscaled preview for image records
///     search/<uuid>.txt the encrypted full-text body, for full-text search
///     search-index/segment-XX.json authenticated inverted-index segments
///     smart-filters.json versioned saved queries
///     pending/<uuid>.json payload metadata not yet committed by both indexes
///     tombstones/<uuid>.json durable proof that a payload must not be rebuilt
///     recovery/<run>/   damaged indexes and undecodable orphan files, never auto-deleted
///
/// The index is small enough to keep entirely in memory and to rewrite atomically, so
/// there is no database. Every regular file below the root is an authenticated AES-GCM
/// envelope; the 256-bit master key lives in Keychain. Payloads live in their own files
/// because a single
/// screenshot can outweigh the entire rest of the history; keeping them out of the
/// index is what makes opening the panel instant no matter how long the history is.
///
/// Every mutating method is main-thread only. File writes for payloads happen on a
/// background queue, and the index write is debounced.
final class ClipStore {
    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.store")

    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/hyper/clipboard", isDirectory: true)

    /// SwiftPM/Xcode launch products are not the signed `/Applications` install and the
    /// fixed Key Broker correctly refuses them. Letting such a process open the production
    /// history anyway turns the whole session into read-only recovery and can make a QA
    /// copy look like the user's real app has stopped recording. A process-local directory
    /// keeps development launches useful without touching production bytes or Keychain.
    static func defaultDirectory(
        bundleURL: URL = Bundle.main.bundleURL,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        let standardized = bundleURL.standardizedFileURL.path
        guard standardized.contains("/.build/") else { return directory }
        return temporaryDirectory.appendingPathComponent(
            "Hyper-Clipboard-Development-\(processIdentifier)", isDirectory: true
        )
    }

    /// Injectable so tests can run against a temporary directory instead of the real
    /// history.
    private let root: URL
    private let vault: ClipboardVault

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var backupIndexURL: URL { root.appendingPathComponent("index.json.backup") }
    private var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var thumbDirectory: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    private var searchDirectory: URL { root.appendingPathComponent("search", isDirectory: true) }
    private var searchIndexDirectory: URL {
        root.appendingPathComponent("search-index", isDirectory: true)
    }
    private var pendingDirectory: URL { root.appendingPathComponent("pending", isDirectory: true) }
    private var tombstoneDirectory: URL { root.appendingPathComponent("tombstones", isDirectory: true) }
    private var recoveryDirectory: URL { root.appendingPathComponent("recovery", isDirectory: true) }
    /// The sentinel written once by this build's initialization. Its presence is both
    /// what `validateExistingVaultKey` authenticates against and what lets a launch
    /// trust `index.json` alone — see `quickInspectIndex`.
    private static let keyCheckName = ".vault-keycheck"
    private var keyCheckURL: URL { root.appendingPathComponent(Self.keyCheckName) }
    private var indexTransactionURL: URL { root.appendingPathComponent("index.transaction") }
    private var smartFiltersURL: URL { root.appendingPathComponent("smart-filters.json") }
    private var migrationManifestURL: URL {
        root.deletingLastPathComponent().appendingPathComponent(
            ".\(root.lastPathComponent).vault-migration.json"
        )
    }
    private static let keyCheckPlaintext = Data("Hyper Clipboard Vault Key Check v1".utf8)

    struct MigrationFaultInjection {
        var crashAfterSwap = false
        var failDuringCleanupAfterRemovingOneEntry = false
    }

    private let migrationFault: MigrationFaultInjection?

    private(set) var records: [ClipRecord] = []

    /// A missing, corrupt or unavailable historical key is never papered over with a new
    /// empty history. Callers can surface this state and export the recovery descriptor;
    /// every mutating entry point fails closed while it is active.
    var vaultState: ClipboardVaultAccessState { vault.state }
    var isReadOnlyRecovery: Bool {
        if case .readOnlyRecovery = vault.state { return true }
        return false
    }

    /// Bumped on every change so views can refresh without diffing the whole array.
    private(set) var generation: UInt64 = 0

    private let io: DispatchQueue
    private var flushWorkItem: DispatchWorkItem?
    private var flushToken: FlushToken?
    /// Main-thread mutation epoch encoded in every index snapshot.
    private var indexEpoch: UInt64 = 0
    /// Accessed only on `io`.
    private var lastCommittedEpoch: UInt64 = 0
    private var failedPayloadIDs: Set<UUID> = []
    /// Payload reads occur on preview/drag queues. This immutable-value map is the
    /// thread-safe bridge to the authenticated index digest for post-decrypt checking.
    private let digestLock = NSLock()
    private var payloadDigests: [UUID: String] = [:]

    /// Digest → id, the reverse of `payloadDigests`, main-thread only like `records`.
    ///
    /// Re-copying something already in the history is what collapses onto an existing
    /// row, and that lookup used to compare the new digest against every record in the
    /// list — 64 hex characters at a time, on the main thread, for every single capture,
    /// with the *miss* (a genuinely new copy) being the case that always paid in full.
    /// A hit is re-checked against the record it names, so a stale entry can only ever
    /// cost a duplicate row; it can never bump the wrong one.
    private var digestToID: [String: UUID] = [:]

    /// Set only when this launch could not trust `index.json`. In that state unknown
    /// files are evidence, not garbage: orphan reconciliation moves them to the recovery
    /// incident instead of deleting them.
    private var recoveryIncidentDirectory: URL?
    private var quarantineOrphans = false

    /// Positive proof that every protected file in this tree is a v2 envelope, from a
    /// complete walk: at `init`, from a verified migration, or from the deferred walk
    /// `loadIndex` runs before anything is loaded.
    ///
    /// `reconcileOrphans` deletes only under this flag. The launch fast path reads one
    /// file, and until the rest of the tree has actually been looked at, an unknown file
    /// could be an injected plaintext payload — which is evidence to be quarantined, not
    /// garbage to be deleted.
    private var isLayoutVerifiedFreeOfForeignPayloads = false

    /// Full-text bodies, main-thread only like every other piece of mutable state here.
    /// Read out through `searchSnapshot()` when a scan needs to happen off the main
    /// thread — the dictionary is copy-on-write, so handing it over costs a retain.
    private var searchIndex: [UUID: ClipSearchEntry] = [:]
    /// Token postings live separately from the bodies. Queries narrow to a small id set
    /// here before verifying phrase/fuzzy matches against `searchIndex`, so 5,000 × 32K
    /// libraries do not rescan every character for every keystroke.
    private var invertedSearchIndex = ClipSearchIndex.empty

    /// The ids the token postings still hold. Every query result is intersected with
    /// `records` before it is returned, so a row left behind in the postings is
    /// invisible from the outside — which makes this the only way to prove that the
    /// deletion paths really do purge it, rather than relying on that filter forever.
    /// Main-thread state, like everything else it reads.
    var indexedDocumentIDs: Set<UUID> { invertedSearchIndex.documentIDs }
    /// Segment persistence is coalesced by slot. The lock spans the main-thread
    /// scheduler and the serial IO worker so an older captured index can never overwrite
    /// a later mutation, even when encoding starts after a newer job was queued.
    private let searchSegmentEpochLock = NSLock()
    private var searchSegmentEpochs: [Int: UInt64] = [:]
    private var pendingSearchSegmentSlots: Set<Int> = []
    private var pendingSearchSegmentIndex: ClipSearchIndex?
    private var isSearchSegmentWorkerScheduled = false
    /// False while startup has only previews and any launch-window captures. During
    /// that short interval callers receive no inverted index and use the complete
    /// linear verifier, preserving the pre-index guarantee that search never goes blank.
    private var isInvertedSearchReady = false
    private let searchQueryQueue = DispatchQueue(
        label: "com.indincys.hyper.clipstore.query", qos: .userInitiated,
        attributes: .concurrent
    )
    private var activeSearchToken: ClipSearchCancellationToken?
    private(set) var smartFilters = SmartFilterStore.empty
    private(set) var areSmartFiltersLoaded = false
    private var smartFilterLoadWaiters: [() -> Void] = []

    /// A history's worth of sidecar files takes a moment to read; the panel wants to
    /// know when it can search the whole thing rather than just the previews.
    var onSearchIndexLoaded: (() -> Void)?

    /// The ids `sweep` just evicted. Retention is the one deletion path the store drives
    /// on its own — every other one goes through a caller that knows what it deleted —
    /// and the paste queue holds ids rather than payloads, so an eviction nobody reports
    /// leaves it counting rows that no longer exist and dispensing nothing when asked.
    /// Called synchronously, on the main thread, at the end of the sweep.
    var onEvicted: (([UUID]) -> Void)?

    /// Reads that happen once at launch. Separate from `io` so neither the index read
    /// nor the sidecar scan can sit in front of the payload write for something the
    /// user just copied. Serial, so the two reads never compete with each other either.
    private let loadQueue: DispatchQueue

    /// Whether `records` reflects what is on disk. False for the first moments after
    /// launch, while the index is still being read.
    private(set) var isLoaded = false
    private var loadWaiters: [() -> Void] = []

    private struct RecoveredPayload {
        var id: UUID
        var createdAt: Date
        var payload: ClipPayload
        var pendingRecord: ClipRecord?
    }

    private struct IndexEnvelope: Codable {
        var version = 1
        var epoch: UInt64
        var records: [ClipRecord]
    }

    private struct DecodedIndex {
        var epoch: UInt64
        var records: [ClipRecord]
        var plaintextHash: String = ""
    }

    private struct PendingRecord: Codable {
        var epoch: UInt64
        var record: ClipRecord
    }

    private struct Tombstone: Codable {
        var epoch: UInt64
        var id: UUID
    }

    /// One file naming many ids, for the wholesale deletions — 清空, 清空未收藏, and a
    /// retention sweep that has thousands of rows to evict. The per-id file below is
    /// unchanged and is still what a single deletion writes; recovery reads both.
    private struct TombstoneBatch: Codable {
        var version = 1
        var epoch: UInt64
        var ids: [UUID]
    }

    /// Filename prefix that tells the two formats apart. A per-id tombstone is named
    /// after its UUID, which can never start with this.
    private static let tombstoneBatchPrefix = "batch-"

    private struct IndexLoadResult {
        var records: [ClipRecord] = []
        var recoveredPayloads: [RecoveredPayload] = []
        var epoch: UInt64 = 0
        var requiresRecovery = false
        var needsSynchronousCommit = false
        var incidentDirectory: URL?
    }

    private final class DrainResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class FlushToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    var retentionDays = 30
    var maxItems = 1000

    /// How much of an entry's body is handed to `ClipCapture.contentTag`. It bounds its
    /// own work again inside, but slicing here is what keeps a multi-megabyte copy from
    /// being trimmed and scanned at all on the capture path.
    private static let tagSourceLimit = 64 * 1024

    init(
        root: URL = ClipStore.defaultDirectory(),
        vault: ClipboardVault? = nil,
        ioQueue: DispatchQueue? = nil,
        loadQueue: DispatchQueue? = nil,
        migrationFault: MigrationFaultInjection? = nil
    ) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        if let vault {
            self.vault = vault
        } else if root.standardizedFileURL.resolvingSymlinksInPath()
                    == Self.directory.standardizedFileURL.resolvingSymlinksInPath() {
            self.vault = ClipboardVault()
        } else {
            self.vault = ClipboardVault(
                provider: EphemeralClipboardVaultKeyProvider(
                    scope: root.standardizedFileURL.resolvingSymlinksInPath().path
                )
            )
        }
        self.io = ioQueue ?? DispatchQueue(
            label: "com.indincys.hyper.clipstore", qos: .utility
        )
        self.loadQueue = loadQueue ?? DispatchQueue(
            label: "com.indincys.hyper.clipstore.load", qos: .utility
        )
        self.migrationFault = migrationFault
        let layout = Self.inspectLibrary(at: self.root)
        let access = self.vault.prepare(library: layout.disposition)
        if case let .readOnlyRecovery(reason) = access {
            log.error("clipboard vault unavailable at launch reason=\(reason.rawValue, privacy: .public)")
        }
        if access == .ready, layout.hasEncryptedV2,
           !validateExistingVaultKey(using: layout) {
            self.vault.markAuthenticationFailed()
        }
        if self.vault.isReady, layout.hasEncryptedV2 {
            recoverInterruptedMigrationIfNeeded()
        }
        var migrated = false
        if self.vault.isReady, layout.needsMigration {
            let outcome = migrateLegacyLibrary(using: layout)
            if outcome == .failed { self.vault.markMigrationFailed() }
            if outcome == .cleanupIncomplete { self.vault.markCleanupIncomplete() }
            // The shadow tree was built entirely by `vault.seal` and then verified file
            // by file, so a migrated library is v2 by construction.
            migrated = outcome == .migrated
        }
        if self.vault.isReady {
            createDirectories()
            createKeyCheckIfNeeded()
            do { try self.vault.finalizeInitialization() }
            catch { self.vault.markAuthenticationFailed() }
        }
        // A full walk at `init` already answered the question; a quick inspection did
        // not, and `loadIndex` finishes it before the history becomes visible.
        if self.vault.isReady {
            isLayoutVerifiedFreeOfForeignPayloads =
                migrated || layout.isVerifiedFreeOfForeignPayloads
        }
        loadIndex(verifyLayout: self.vault.isReady && layout.isQuickInspection)
        // Queued behind the index read on purpose: the permission repair is a walk over
        // the whole library, and nothing the user can see is waiting for it.
        if self.vault.isReady { scheduleFileModeMaintenance() }
    }

    /// Runs `body` on the main thread once the index is in memory — immediately if it
    /// already is. Anything that reads `records` at launch has to go through this,
    /// because the read from disk no longer finishes before `init` returns.
    func whenLoaded(_ body: @escaping () -> Void) {
        guard !isLoaded else {
            body()
            return
        }
        loadWaiters.append(body)
    }

    /// Deterministic main-thread readiness for saved-query UI. Unlike a delay or poll,
    /// this covers empty, slow, corrupt and read-only stores with exactly one contract.
    func whenSmartFiltersLoaded(_ body: @escaping () -> Void) {
        guard !areSmartFiltersLoaded else {
            body()
            return
        }
        smartFilterLoadWaiters.append(body)
    }

    // MARK: - Disk layout

    private func createDirectories() {
        for url in [
            root, dataDirectory, thumbDirectory, searchDirectory,
            searchIndexDirectory, pendingDirectory, tombstoneDirectory,
        ] {
            do {
                try Self.createSecureDirectory(at: url)
            } catch {
                log.error("cannot create \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try Self.secureExistingDirectoryModes(at: root)
        } catch {
            log.error("cannot enforce clipboard vault permissions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Repairs file modes off the launch path, and only where they are actually wrong.
    ///
    /// Directory modes stay synchronous above: there are seven of them, and the root's
    /// 0700 is what actually keeps another account out of the tree. Per-file 0600 is a
    /// repair for bytes written by an older build — everything this build writes is
    /// created 0600 by `secureAtomicWrite` — so it has no business running on the main
    /// thread, and a `stat` before the `chmod` turns the steady state into a read-only
    /// walk instead of one write syscall per file in the history.
    private func scheduleFileModeMaintenance() {
        let root = self.root
        loadQueue.async { [weak self, log] in
            // Queued behind the deferred layout verification. If that turned the launch
            // into read-only recovery, the tree is evidence and not even its modes are
            // ours to change.
            guard let self, self.vault.isReady else { return }
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)
            else { return }
            var repaired = 0
            for case let url as URL in enumerator {
                // One `lstat` decides both questions — regular file, and already 0600 —
                // and never follows a symlink. `attributesOfItem` would answer the same
                // thing by building a whole attribute dictionary per file, which costs
                // more than the `chmod` this is trying to avoid.
                var info = stat()
                guard lstat(url.path, &info) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG,
                      (info.st_mode & 0o7777) != 0o600
                else { continue }
                do {
                    try fm.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o600))],
                        ofItemAtPath: url.path
                    )
                    repaired += 1
                } catch {
                    log.error("cannot enforce clipboard file permissions at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if repaired > 0 {
                log.info("clipboard vault tightened \(repaired) file permissions")
            }
        }
    }

    /// Blocks until the launch-time permission repair — and any index read queued ahead
    /// of it — has finished. Tests assert the 0600 contract through this; production
    /// never waits for it.
    func waitForMaintenance() {
        loadQueue.sync {}
    }

    private func validateExistingVaultKey(using inspection: LibraryInspection) -> Bool {
        if FileManager.default.fileExists(atPath: keyCheckURL.path),
           let sealed = try? Data(contentsOf: keyCheckURL) {
            return (try? vault.open(
                sealed, context: ClipboardVault.storageContext(relativePath: ".vault-keycheck")
            )) == Self.keyCheckPlaintext
        }
        // Compatibility with an encrypted library written before the sentinel existed:
        // one authenticated file proves the 256-bit key. A single damaged file does not
        // poison a library when another index/payload still authenticates.
        //
        // This is the only caller that needs the whole file list, and it is reached only
        // when the sentinel is missing or unreadable — which is also the one case the
        // launch fast path refuses to handle. Asking for the walk here keeps it off
        // every other launch instead of hiding it behind a lazily recomputed property.
        let files = inspection.isQuickInspection
            ? Self.inspectLibrary(at: root, fullScan: true).files
            : inspection.files
        for file in files {
            guard let sealed = try? Data(contentsOf: file), ClipboardVault.isSealed(sealed) else {
                continue
            }
            guard let relative = Self.relativePath(of: file, under: root) else { continue }
            if (try? vault.open(
                sealed, context: ClipboardVault.storageContext(relativePath: relative)
            )) != nil { return true }
        }
        return false
    }

    private func createKeyCheckIfNeeded() {
        guard !FileManager.default.fileExists(atPath: keyCheckURL.path) else { return }
        do {
            try writeProtectedData(Self.keyCheckPlaintext, to: keyCheckURL)
        } catch {
            vault.markAuthenticationFailed()
            log.error("cannot persist clipboard vault key check")
        }
    }

    func exportVaultRecoveryMaterial() throws -> Data {
        try vault.recoveryMaterial().encoded()
    }

    private struct LibraryInspection {
        /// Every regular file below the root. Collected only by the full walk; a quick
        /// inspection leaves it empty and says so through `isQuickInspection`.
        var files: [URL] = []
        /// True when the layout was decided from `index.json` alone. Nothing below the
        /// root has been looked at, so this inspection proves only that the index is a
        /// v2 envelope — the rest of the tree still owes a walk.
        var isQuickInspection = false
        var hasEncryptedV1 = false
        var hasEncryptedV2 = false
        var hasPlaintext = false
        var hasUnsafeEntry = false

        /// A protected byte this build's writer could not have produced. With a v2
        /// `index.json` overhead — which is the only way the deferred verification is
        /// ever reached — this is exactly the `.invalidOrMixed` disposition below, so
        /// the launch fast path and the full walk reach the same verdict on the same
        /// tree, which is the whole point of the fast path.
        ///
        /// `hasUnsafeEntry` is deliberately *not* part of this. A symbolic link is not
        /// a payload classification: it says nothing about whether the real payloads
        /// are sealed, and the full walk has never treated it as a mixed layout
        /// (`disposition` ignores it). Folding it in here would make the fast path
        /// stricter than the walk it stands in for, and would leave a tree that is
        /// otherwise perfectly healthy permanently read-only.
        var hasForeignPayloadBytes: Bool { hasEncryptedV1 || hasPlaintext }

        /// A completed walk that found nothing foreign — the positive proof
        /// `reconcileOrphans` needs before it may delete a file. An empty library
        /// qualifies; a quick inspection never does, because it walked nothing.
        var isVerifiedFreeOfForeignPayloads: Bool {
            !isQuickInspection && !hasForeignPayloadBytes
        }

        var needsMigration: Bool { hasEncryptedV1 || hasPlaintext }

        var disposition: ClipboardVaultLibraryDisposition {
            let protectedKinds = [hasEncryptedV1, hasEncryptedV2, hasPlaintext]
                .filter { $0 }.count
            if protectedKinds > 1 { return .invalidOrMixed }
            if hasEncryptedV2 { return .encryptedV2 }
            if hasEncryptedV1 { return .encryptedV1 }
            if hasPlaintext { return .legacyPlaintext }
            return .empty
        }
    }

    /// Reads only the envelope header during launch. A library may contain screenshots
    /// tens of megabytes large; deciding whether migration is needed must not duplicate
    /// all of them in memory.
    private static func inspectLibrary(at root: URL, fullScan: Bool = false) -> LibraryInspection {
        var result = LibraryInspection()
        if !fullScan, let quick = quickInspectIndex(at: root) { return quick }
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
              )
        else { return result }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                result.hasUnsafeEntry = true
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            result.files.append(url)
            guard let relative = relativePath(of: url, under: root),
                  isVaultProtectedPath(relative) else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                result.hasUnsafeEntry = true
                continue
            }
            // v2 classification needs its fixed 11-byte header; v1 needs enough bytes
            // to prove that a complete AES-GCM nonce/tag envelope could exist.
            let header = try? handle.read(upToCount: 37)
            try? handle.close()
            if let header, ClipboardVault.isSealed(header) {
                result.hasEncryptedV2 = true
            } else if let header, ClipboardVault.isLegacyV1Sealed(header) {
                result.hasEncryptedV1 = true
            } else {
                result.hasPlaintext = true
            }
        }
        return result
    }

    /// Two `open`/`read`/`close` pairs instead of one per file in the library.
    ///
    /// The tree walk above exists to decide a single question at launch: which vault
    /// generation wrote this library. Two files answer it for a healthy install, and
    /// both have to agree before the walk is skipped:
    ///
    /// - `.vault-keycheck` exists. The sentinel is written once, by this build's own
    ///   initialization, and it is what the key probe below authenticates against. Its
    ///   absence means either a library older than the sentinel or a tree somebody has
    ///   been editing, and both of those are exactly the cases where the complete walk
    ///   earns its cost — including catching a v2 index sitting above a plaintext or
    ///   legacy payload, which is `invalidOrMixed` and must stay read-only.
    /// - `index.json` carries a v2 envelope header. It is written by the same
    ///   authenticated writer as every other protected file, so it stands for them.
    ///
    /// Anything else — no sentinel, no index, a legacy or plaintext or unreadable one —
    /// returns nil and the complete walk runs exactly as before, so migration,
    /// mixed-layout detection and tamper evidence are untouched.
    private static func quickInspectIndex(at root: URL) -> LibraryInspection? {
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent(keyCheckName).path
        ) else { return nil }
        let indexURL = root.appendingPathComponent("index.json")
        guard let handle = try? FileHandle(forReadingFrom: indexURL) else { return nil }
        let header = try? handle.read(upToCount: 37)
        try? handle.close()
        guard let header, ClipboardVault.isSealed(header) else { return nil }
        var result = LibraryInspection()
        result.hasEncryptedV2 = true
        result.isQuickInspection = true
        return result
    }

    /// Legacy migration is a shadow-tree transaction:
    ///
    /// 1. build a mode-0700 sibling tree, encrypting bytes directly from the legacy
    ///    source into mode-0600 files (no plaintext staged copy);
    /// 2. decrypt every shadow file and compare it byte-for-byte with the source, then
    ///    decode both index/journal generations and validate every payload reference;
    /// 3. atomically replace the directory while retaining FileManager's rollback copy;
    /// 4. validate the live tree again before deleting that rollback copy.
    ///
    /// Any failure before the switch leaves the legacy directory untouched. A failure
    /// after it restores the backup and puts the store in explicit read-only recovery.
    private enum MigrationOutcome { case migrated, failed, cleanupIncomplete }

    private struct MigrationManifest: Codable {
        enum Phase: String, Codable { case preparing, readyToSwap, swapped, cleaning }
        var version = 1
        var shadowName: String
        var phase: Phase
    }

    /// The manifest is outside the swapped directory, contains no clipboard content and
    /// is mode 0600. Its phase is advisory: the root's authenticated layout decides
    /// which tree is truth after a crash.
    private func writeMigrationManifest(_ manifest: MigrationManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.secureAtomicWrite(try encoder.encode(manifest), to: migrationManifestURL)
    }

    private func recoverInterruptedMigrationIfNeeded() {
        let fm = FileManager.default
        let prefix = ".\(root.lastPathComponent).vault-shadow-"
        var shadowURLs: [URL] = []
        if let data = try? Data(contentsOf: migrationManifestURL),
           let manifest = try? JSONDecoder().decode(MigrationManifest.self, from: data),
           manifest.version == 1, manifest.shadowName.hasPrefix(prefix),
           !manifest.shadowName.contains("/") {
            shadowURLs.append(root.deletingLastPathComponent().appendingPathComponent(
                manifest.shadowName, isDirectory: true
            ))
        }
        if let names = try? fm.contentsOfDirectory(atPath: root.deletingLastPathComponent().path) {
            shadowURLs.append(contentsOf: names.filter { $0.hasPrefix(prefix) }.map {
                root.deletingLastPathComponent().appendingPathComponent($0, isDirectory: true)
            })
        }
        shadowURLs = Array(Set(shadowURLs))
        guard !shadowURLs.isEmpty || fm.fileExists(atPath: migrationManifestURL.path) else { return }

        // Startup only enters here after the live root authenticated with the trusted key.
        // It is therefore the encrypted truth; a partial plaintext rollback is never used.
        do {
            for shadow in shadowURLs where fm.fileExists(atPath: shadow.path) {
                try Self.secureExistingTreeModes(at: shadow)
                try fm.removeItem(at: shadow)
            }
            if fm.fileExists(atPath: migrationManifestURL.path) {
                try fm.removeItem(at: migrationManifestURL)
            }
            log.info("clipboard vault resumed and completed legacy-shadow cleanup")
        } catch {
            vault.markCleanupIncomplete()
            log.error("clipboard vault cleanup recovery remains incomplete: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func migrateLegacyLibrary(using inspection: LibraryInspection) -> MigrationOutcome {
        guard !inspection.hasUnsafeEntry else {
            log.error("clipboard vault migration refused a symlink or unreadable entry")
            return .failed
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return .migrated }
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        let shadow = parent.appendingPathComponent(
            ".\(root.lastPathComponent).vault-shadow-\(UUID().uuidString)", isDirectory: true
        )
        var manifest = MigrationManifest(shadowName: shadow.lastPathComponent, phase: .preparing)
        var isSwapped = false
        var liveVerified = false
        var cleanupStarted = false

        do {
            try writeMigrationManifest(manifest)
            try Self.createSecureDirectory(at: shadow)
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            ) else { throw ClipboardVaultMigrationError.enumerationFailed }

            for case let source as URL in enumerator {
                let values = try source.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else {
                    throw ClipboardVaultMigrationError.unsafeEntry(source.path)
                }
                guard let relative = Self.relativePath(of: source, under: root) else {
                    throw ClipboardVaultMigrationError.unsafeEntry(source.path)
                }
                let destination = shadow.appendingPathComponent(relative)
                if values.isDirectory == true {
                    try Self.createSecureDirectory(at: destination)
                } else if values.isRegularFile == true {
                    let sourceData = try Data(contentsOf: source, options: [.mappedIfSafe])
                    let staged: Data
                    if Self.isVaultProtectedPath(relative) {
                        let plaintext: Data
                        if ClipboardVault.isLegacyV1Sealed(sourceData) {
                            plaintext = try vault.openLegacyV1(sourceData)
                        } else if ClipboardVault.isSealed(sourceData) {
                            plaintext = try vault.open(
                                sourceData,
                                context: ClipboardVault.storageContext(relativePath: relative)
                            )
                        } else {
                            plaintext = sourceData
                        }
                        staged = try vault.seal(
                            plaintext,
                            context: ClipboardVault.storageContext(relativePath: relative)
                        )
                    } else {
                        // `queue.json` is a separate UUID-only protocol owned by
                        // PasteQueue. It has no recognisable clipboard body and must
                        // remain decodable by that owner across the directory swap.
                        staged = sourceData
                    }
                    try Self.secureAtomicWrite(staged, to: destination)
                } else {
                    throw ClipboardVaultMigrationError.unsafeEntry(source.path)
                }
            }

            guard verifyMigratedTree(source: root, encrypted: shadow) else {
                throw ClipboardVaultMigrationError.verificationFailed
            }

            // Close the otherwise unavoidable syscall-sized window between the atomic
            // directory swap and making the old plaintext tree private.
            try Self.secureExistingTreeModes(at: root)
            manifest.phase = .readyToSwap
            try writeMigrationManifest(manifest)
            try Self.atomicSwap(root, shadow)
            isSwapped = true
            // The old plaintext tree becomes private before any injectable crash point.
            try Self.secureExistingTreeModes(at: shadow)
            guard verifyEncryptedLibrary(at: root), verifySecureModes(at: root) else {
                throw ClipboardVaultMigrationError.liveVerificationFailed
            }
            liveVerified = true
            manifest.phase = .swapped
            try writeMigrationManifest(manifest)
            if migrationFault?.crashAfterSwap == true {
                throw ClipboardVaultMigrationError.injectedAfterSwapCrash
            }

            manifest.phase = .cleaning
            try writeMigrationManifest(manifest)
            cleanupStarted = true
            if migrationFault?.failDuringCleanupAfterRemovingOneEntry == true {
                if let first = try fm.contentsOfDirectory(
                    at: shadow, includingPropertiesForKeys: nil
                ).first {
                    try fm.removeItem(at: first)
                }
                throw ClipboardVaultMigrationError.injectedPartialCleanupFailure
            }
            try fm.removeItem(at: shadow)
            try fm.removeItem(at: migrationManifestURL)
            log.info("clipboard library migrated to authenticated encryption")
            return .migrated
        } catch {
            if isSwapped && !liveVerified && !cleanupStarted,
               fm.fileExists(atPath: root.path), fm.fileExists(atPath: shadow.path) {
                do {
                    try Self.atomicSwap(root, shadow)
                    isSwapped = false
                } catch {
                    log.error("clipboard vault pre-cleanup rollback failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if isSwapped && liveVerified {
                // Once encrypted live authenticated, it remains the sole truth even if
                // cleanup already removed only part of the old plaintext tree.
                log.error("clipboard vault encrypted live retained; cleanup is incomplete: \(error.localizedDescription, privacy: .public)")
                return .cleanupIncomplete
            }
            if fm.fileExists(atPath: shadow.path) { try? fm.removeItem(at: shadow) }
            try? fm.removeItem(at: migrationManifestURL)
            log.error("clipboard vault migration failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private enum ClipboardVaultMigrationError: LocalizedError {
        case enumerationFailed
        case unsafeEntry(String)
        case verificationFailed
        case liveVerificationFailed
        case atomicSwapFailed(Int32)
        case injectedAfterSwapCrash
        case injectedPartialCleanupFailure

        var errorDescription: String? {
            switch self {
            case .enumerationFailed: return "cannot enumerate legacy clipboard tree"
            case let .unsafeEntry(path): return "unsafe clipboard tree entry: \(path)"
            case .verificationFailed: return "shadow-tree verification failed"
            case .liveVerificationFailed: return "post-switch verification failed"
            case let .atomicSwapFailed(code): return "atomic directory swap failed (errno \(code))"
            case .injectedAfterSwapCrash: return "injected crash after atomic migration switch"
            case .injectedPartialCleanupFailure: return "injected partial legacy cleanup failure"
            }
        }
    }

    private static func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw ClipboardVaultMigrationError.atomicSwapFailed(errno) }
    }

    private func verifyMigratedTree(source: URL, encrypted: URL) -> Bool {
        let sourceInspection = Self.inspectLibrary(at: source, fullScan: true)
        let encryptedInspection = Self.inspectLibrary(at: encrypted, fullScan: true)
        guard !sourceInspection.hasUnsafeEntry, !encryptedInspection.hasUnsafeEntry,
              encryptedInspection.hasEncryptedV2,
              !encryptedInspection.hasEncryptedV1,
              !encryptedInspection.hasPlaintext,
              sourceInspection.files.count == encryptedInspection.files.count
        else { return false }

        let encryptedPairs: [(String, URL)] = encryptedInspection.files.compactMap {
            guard let relative = Self.relativePath(of: $0, under: encrypted) else { return nil }
            return (relative, $0)
        }
        let encryptedByRelative = Dictionary(uniqueKeysWithValues: encryptedPairs)
        for sourceFile in sourceInspection.files {
            guard let relative = Self.relativePath(of: sourceFile, under: source) else {
                return false
            }
            guard let target = encryptedByRelative[relative],
                  let sourceRaw = try? Data(contentsOf: sourceFile, options: [.mappedIfSafe]),
                  let targetRaw = try? Data(contentsOf: target, options: [.mappedIfSafe])
            else { return false }
            guard Self.isVaultProtectedPath(relative) else {
                guard targetRaw == sourceRaw else { return false }
                continue
            }
            guard ClipboardVault.isSealed(targetRaw),
                  let targetPlain = try? vault.open(
                    targetRaw,
                    context: ClipboardVault.storageContext(relativePath: relative)
                  ) else { return false }
            let sourcePlain: Data
            if ClipboardVault.isSealed(sourceRaw) {
                guard let opened = try? vault.open(
                    sourceRaw,
                    context: ClipboardVault.storageContext(relativePath: relative)
                ) else { return false }
                sourcePlain = opened
            } else if ClipboardVault.isLegacyV1Sealed(sourceRaw) {
                guard let opened = try? vault.openLegacyV1(sourceRaw) else { return false }
                sourcePlain = opened
            } else {
                sourcePlain = sourceRaw
            }
            guard targetPlain == sourcePlain else { return false }
        }
        return verifyEncryptedLibrary(at: encrypted) && verifySecureModes(at: encrypted)
    }

    private static func relativePath(of child: URL, under root: URL) -> String? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let leaf = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard leaf.count > base.count, Array(leaf.prefix(base.count)) == base else { return nil }
        let relative = leaf.dropFirst(base.count).joined(separator: "/")
        return relative.isEmpty ? nil : relative
    }

    private static func isVaultProtectedPath(_ relative: String) -> Bool {
        if relative == "index.json" || relative == "index.json.backup"
            || relative == "index.transaction" || relative == "smart-filters.json"
            || relative == ".vault-keycheck" { return true }
        guard let first = relative.split(separator: "/", maxSplits: 1).first else { return false }
        return ["data", "thumbs", "search", "search-index", "pending", "tombstones", "recovery"]
            .contains(String(first))
    }

    private func verifyEncryptedLibrary(at candidate: URL) -> Bool {
        let index = candidate.appendingPathComponent("index.json")
        let backup = candidate.appendingPathComponent("index.json.backup")
        var indexes: [DecodedIndex] = []
        for url in [index, backup] where FileManager.default.fileExists(atPath: url.path) {
            // Corrupt indexes are an existing Wave-1 recovery input. Their ciphertext
            // has already passed byte-for-byte round-trip verification above; keeping
            // them lets the normal loader quarantine and rebuild without migration
            // turning a recoverable library into a permanently blocked one.
            if let decoded = try? decodeIndex(at: url, under: candidate) { indexes.append(decoded) }
        }

        // Brand-new, fully cleared and both-index-corrupt stores have no selectable
        // snapshot. The regular recovery pass validates/rebuilds payloads after switch.
        if indexes.isEmpty { return true }
        guard let selected = indexes.max(by: { $0.epoch < $1.epoch }) else { return false }
        let candidateData = candidate.appendingPathComponent("data", isDirectory: true)
        for record in selected.records where !record.oversized {
            let url = candidateData.appendingPathComponent("\(record.id.uuidString).plist")
            // Missing payloads were already recoverable evidence in Wave 1. Migration
            // must preserve that degraded graph exactly rather than delete or invent it.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // A digest mismatch is also a Wave-1 recovery input (payload write newer
            // than its surviving backup index). Requiring equality here would block
            // precisely the launch that repairs the stale metadata; authenticated
            // decryption plus payload decoding proves migration preserved the reference.
            guard let sealed = try? Data(contentsOf: url),
                  let relative = Self.relativePath(of: url, under: candidate),
                  let plain = try? vault.open(
                    sealed,
                    context: ClipboardVault.storageContext(relativePath: relative)
                  ),
                  ClipPayloadCoder.decode(plain) != nil
            else { return false }
        }

        return true
    }

    private func verifySecureModes(at candidate: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: candidate,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else { return false }
        guard Self.posixMode(at: candidate) == 0o700 else { return false }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true, Self.posixMode(at: url) != 0o700 { return false }
            if values?.isRegularFile == true, Self.posixMode(at: url) != 0o600 { return false }
        }
        return true
    }

    private static func posixMode(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    private static func createSecureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path
        )
    }

    /// The root plus every directory below it. Cheap, bounded by the fixed layout, and
    /// the only half of the mode contract a launch has to establish before it returns.
    private static func secureExistingDirectoryModes(at root: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: root.path
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path
            )
        }
    }

    /// Directories and files in one synchronous pass. Migration keeps this: the window
    /// between the atomic swap and the old plaintext tree becoming private is measured
    /// in syscalls, and cannot be handed to another queue.
    private static func secureExistingTreeModes(at root: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: root.path
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path
                )
            } else if values.isRegularFile == true {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path
                )
            }
        }
    }

    /// Atomic writer whose temporary file contains ciphertext and starts life as 0600.
    /// Foundation's `Data.write(.atomic)` does not expose the staged file's attributes,
    /// so it cannot prove the staged-file part of the vault contract.
    private static func secureAtomicWrite(_ ciphertext: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try createSecureDirectory(at: parent)
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".hyper-vault-write-\(UUID().uuidString).tmp"
        )
        let fm = FileManager.default
        guard fm.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: ciphertext)
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: url.path) {
                // `replaceItemAt` preserves the *original* item's metadata by default,
                // so overwriting a file some earlier build (or somebody's editor) left
                // at 0644 silently kept it there — the staged file's 0600 was thrown
                // away. Ask for the new item's metadata, and then say it again with a
                // chmod, because this is the one guarantee the vault contract rests on.
                _ = try fm.replaceItemAt(
                    url, withItemAt: temporary, options: [.usingNewMetadataOnly]
                )
            } else {
                try fm.moveItem(at: temporary, to: url)
            }
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path
            )
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private func readProtectedData(at url: URL, revision: String? = nil) throws -> Data {
        try readProtectedData(at: url, under: root, revision: revision)
    }

    private func readProtectedData(
        at url: URL, under base: URL, revision: String? = nil
    ) throws -> Data {
        let envelope = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let relative = Self.relativePath(of: url, under: base) else {
            throw ClipboardVaultError.contextMismatch
        }
        return try vault.open(
            envelope,
            context: ClipboardVault.storageContext(
                relativePath: relative, revision: revision
            )
        )
    }

    private func writeProtectedData(
        _ plaintext: Data, to url: URL, revision: String? = nil
    ) throws {
        guard vault.isReady else {
            let reason: ClipboardVaultRecoveryReason
            if case let .readOnlyRecovery(value) = vault.state {
                reason = value
            } else {
                reason = .keychainUnavailable
            }
            throw ClipboardVaultError.notReady(reason)
        }
        guard let relative = Self.relativePath(of: url, under: root) else {
            throw ClipboardVaultError.contextMismatch
        }
        try Self.secureAtomicWrite(
            try vault.seal(
                plaintext,
                context: ClipboardVault.storageContext(
                    relativePath: relative, revision: revision
                )
            ),
            to: url
        )
    }

    /// Blocks until the two internal queues are idle. Retained for tests that need to
    /// observe background sidecars; production shutdown should use the bounded drain.
    func waitForPendingWrites() {
        loadQueue.sync {}
        io.sync {}
    }

    /// Commits the newest index snapshot strictly after every payload/sidecar operation
    /// already accepted by the store, waiting no longer than `timeout`.
    ///
    /// The load queue fence matters because its legacy-search backfill can enqueue file
    /// writes of its own. The final index write is placed on `io` from behind that fence,
    /// so success proves both queues reached a point where the snapshot and every payload
    /// visible when this method was called are durable. A timed-out operation is not
    /// cancelled halfway through an atomic write; it finishes safely in the background,
    /// while the false result lets a lifecycle owner avoid claiming shutdown is complete.
    @discardableResult
    func drainPendingWrites(timeout: TimeInterval) -> Bool {
        guard timeout.isFinite, timeout >= 0 else {
            log.error("pending-write drain rejected an invalid timeout")
            return false
        }
        guard isLoaded, vault.isReady else {
            log.error("pending-write drain cannot commit before the index has loaded")
            return false
        }

        flushToken?.cancel()
        flushToken = nil
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let snapshot = records
        let epoch = indexEpoch
        let token = FlushToken()
        let completed = DispatchSemaphore(value: 0)
        let result = DrainResult()

        loadQueue.async { [weak self] in
            guard let self else {
                completed.signal()
                return
            }
            self.io.async { [weak self] in
                guard let self else {
                    completed.signal()
                    return
                }
                guard !token.isCancelled else {
                    completed.signal()
                    return
                }
                result.set(self.writeIndexSnapshot(snapshot, epoch: epoch, token: token))
                completed.signal()
            }
        }

        guard completed.wait(timeout: .now() + timeout) == .success else {
            token.cancel()
            log.error("pending-write drain timed out after \(timeout, privacy: .public)s")
            return false
        }
        return result.get()
    }

    private func payloadURL(_ id: UUID) -> URL {
        dataDirectory.appendingPathComponent("\(id.uuidString).plist")
    }

    private func thumbnailURL(_ id: UUID) -> URL {
        thumbDirectory.appendingPathComponent("\(id.uuidString).png")
    }

    private func searchTextURL(_ id: UUID) -> URL {
        searchDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    private func searchSegmentURL(_ slot: Int) -> URL {
        searchIndexDirectory.appendingPathComponent(
            String(format: "segment-%02d.json", slot)
        )
    }

    private func pendingURL(_ id: UUID) -> URL {
        pendingDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func tombstoneURL(_ id: UUID) -> URL {
        tombstoneDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Index

    /// A thousand entries is about a megabyte of JSON; reading and decoding that on the
    /// main thread is a visible pause on a hotkey-driven app whose whole promise is that
    /// it is there the instant you ask for it. So the read and the decode happen in the
    /// background and only the array assignment comes back to the main thread, which
    /// keeps the "mutating state is main-thread only" rule intact.
    ///
    /// Nothing waits on this: capture works from the first moment, and the panel shows
    /// an empty list for the handful of milliseconds before `historyChanged` refreshes
    /// it. Everything that reads `records` at launch goes through `whenLoaded`.
    private func loadIndex(verifyLayout: Bool = false) {
        guard vault.canDecrypt else {
            DispatchQueue.main.async { [weak self] in self?.finishReadOnlyLoad() }
            return
        }
        loadQueue.async { [weak self] in
            guard let self else { return }
            // Strictly before the index is read, not merely before it is adopted. A
            // mixed tree is evidence, and `readIndexAndRecoveryPayloads` is allowed to
            // move a damaged index into a recovery incident — which is exactly the kind
            // of rewriting that must not happen to a library somebody has been editing.
            if verifyLayout, !self.verifyDeferredLayout() {
                DispatchQueue.main.async { self.rejectInvalidLayout() }
                return
            }
            let result = self.readIndexAndRecoveryPayloads()
            guard self.vault.canDecrypt else {
                DispatchQueue.main.async { [weak self] in self?.finishReadOnlyLoad() }
                return
            }
            DispatchQueue.main.async {
                if verifyLayout { self.isLayoutVerifiedFreeOfForeignPayloads = true }
                self.adoptLoadedIndex(result)
            }
        }
    }

    /// The walk the launch fast path deferred. Runs on `loadQueue`, and does the walk
    /// itself on `io` — the serial queue every payload, index and journal write goes
    /// through — so a staging file caught halfway through `secureAtomicWrite` can never
    /// be mistaken for a plaintext one.
    ///
    /// Returns whether the tree may be loaded. Called on `loadQueue` only.
    private func verifyDeferredLayout() -> Bool {
        let inspection = io.sync { Self.inspectLibrary(at: root, fullScan: true) }
        guard inspection.hasForeignPayloadBytes else { return true }
        vault.markProtectedLayoutInvalid()
        log.error("clipboard layout verification found a non-v2 file; the library is read-only evidence")
        return false
    }

    /// Exactly what the synchronous walk produced before the fast path existed: nothing
    /// is loaded, nothing is rewritten, and `reconcileOrphans` cannot run at all while
    /// the vault is not ready — so every byte of the mixed tree survives for export.
    private func rejectInvalidLayout() {
        quarantineOrphans = true
        isLayoutVerifiedFreeOfForeignPayloads = false
        finishReadOnlyLoad()
    }

    private func finishReadOnlyLoad() {
        guard !isLoaded else { return }
        records = []
        // The derived indexes go with them. A launch-window capture can have put rows in
        // both, and a digest left behind would collapse the next copy onto a row nothing
        // can show, paste or delete.
        digestToID = [:]
        digestLock.lock()
        payloadDigests = [:]
        digestLock.unlock()
        searchIndex = [:]
        invertedSearchIndex = .empty
        isInvertedSearchReady = true
        finishSmartFilterLoad(.empty)
        isLoaded = true
        generation &+= 1
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter() }

        onSearchIndexLoaded?()
        let reason: String
        if case let .readOnlyRecovery(value) = vault.state { reason = value.rawValue }
        else { reason = ClipboardVaultRecoveryReason.keychainUnavailable.rawValue }
        log.error("clipboard vault opened in explicit read-only recovery mode reason=\(reason, privacy: .public)")
    }

    /// Chooses the highest-epoch valid index, then replays durable pending records and
    /// tombstones. A decodable-but-stale primary therefore cannot outrank a newer backup,
    /// and payloads accepted after either snapshot are named by a pending record rather
    /// than guessed from the orphan directory.
    private func readIndexAndRecoveryPayloads() -> IndexLoadResult {
        let fm = FileManager.default
        let primaryExists = fm.fileExists(atPath: indexURL.path)
        let backupExists = fm.fileExists(atPath: backupIndexURL.path)
        let interruptedRecovery = !primaryExists && !backupExists && hasRecoveryEvidence()
        var primary: DecodedIndex?
        var backup: DecodedIndex?
        var transaction: DecodedIndex?
        var damaged: [URL] = []
        if primaryExists {
            do { primary = try decodeIndex(at: indexURL) }
            catch {
                damaged.append(indexURL)
                log.error("clipboard primary index is unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
        if backupExists {
            do { backup = try decodeIndex(at: backupIndexURL) }
            catch {
                damaged.append(backupIndexURL)
                log.error("clipboard backup index is unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
        if FileManager.default.fileExists(atPath: indexTransactionURL.path) {
            do { transaction = try decodeIndex(at: indexTransactionURL) }
            catch {
                damaged.append(indexTransactionURL)
                log.error("clipboard index transaction is unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard vault.canDecrypt else {
            // Authentication failure means a wrong/damaged key is possible. Moving,
            // deleting or rewriting any historical byte would destroy recovery evidence.
            return IndexLoadResult(requiresRecovery: true)
        }

        let expectation = vault.indexExpectation()
        let selected: DecodedIndex
        var trustedTransaction = false
        if let pendingEpoch = expectation.pendingEpoch,
           let pendingHash = expectation.pendingHash {
            let matches = [transaction, primary, backup].compactMap { $0 }.filter {
                $0.epoch == pendingEpoch && $0.plaintextHash == pendingHash
            }
            guard let match = matches.first else {
                vault.markRollbackDetected()
                log.error("clipboard index pending high-water has no matching durable snapshot")
                return IndexLoadResult(requiresRecovery: true)
            }
            selected = match
            trustedTransaction = transaction?.epoch == match.epoch
                && transaction?.plaintextHash == match.plaintextHash
        } else if let committedEpoch = expectation.committedEpoch,
                  let committedHash = expectation.committedHash {
            let matches = [primary, backup].compactMap { $0 }.filter {
                $0.epoch == committedEpoch && $0.plaintextHash == committedHash
            }
            guard let match = matches.first else {
                vault.markRollbackDetected()
                log.error("clipboard index replay/rollback rejected by Keychain high-water")
                return IndexLoadResult(requiresRecovery: true)
            }
            selected = match
        } else {
            switch (primary, backup) {
            case let (p?, b?): selected = b.epoch > p.epoch ? b : p
            case let (p?, nil): selected = p
            case let (nil, b?): selected = b
            case (nil, nil): selected = DecodedIndex(epoch: 0, records: [])
            }
        }

        var result = IndexLoadResult(
            records: selected.records,
            epoch: selected.epoch,
            requiresRecovery: !damaged.isEmpty || interruptedRecovery,
            needsSynchronousCommit: primary == nil || backup == nil
                || primary?.epoch != backup?.epoch || trustedTransaction
        )
        if result.requiresRecovery {
            result.incidentDirectory = makeRecoveryIncidentDirectory()
            if let incident = result.incidentDirectory {
                for url in damaged { quarantine(url, in: incident, category: nil) }
            }
        }

        let tombstones = readTombstones()
        let pending = readPendingRecords()
        var changed = false
        var byID: [UUID: ClipRecord] = [:]
        for record in result.records { byID[record.id] = record }

        for (id, tombstone) in tombstones {
            let pendingIsNewer = pending[id].map { $0.epoch > tombstone.epoch } ?? false
            guard !pendingIsNewer, byID[id] != nil, selected.epoch <= tombstone.epoch else { continue }
            byID[id] = nil
            changed = true
        }
        for (id, item) in pending {
            guard item.epoch > selected.epoch else { continue }
            if let tombstone = tombstones[id], tombstone.epoch >= item.epoch { continue }
            guard pendingPayloadIsValid(item) else { continue }
            if byID[id]?.digest != item.record.digest {
                byID[id] = item.record
                changed = true
            }
        }
        if changed {
            result.records = Array(byID.values).sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                if lhs.pinned, lhs.pinnedRank != rhs.pinnedRank {
                    return (lhs.pinnedRank ?? .max) < (rhs.pinnedRank ?? .max)
                }
                return lhs.createdAt > rhs.createdAt
            }
        }

        if result.requiresRecovery {
            let blocked = Set(tombstones.keys.filter { id in
                guard let pendingItem = pending[id], let tombstone = tombstones[id] else { return true }
                return tombstone.epoch >= pendingItem.epoch
            })
            result.recoveredPayloads = recoverablePayloads(excluding: blocked)
            changed = changed || !result.recoveredPayloads.isEmpty
        }
        result.needsSynchronousCommit = result.needsSynchronousCommit || changed
            || !pending.isEmpty || !tombstones.isEmpty
            || (!primaryExists && !backupExists)
        return result
    }

    /// Empty layout directories are created for every store, so only their contents (or
    /// an existing recovery root, which is created solely for an incident) distinguish an
    /// interrupted recovery from a genuinely new library.
    private func hasRecoveryEvidence() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: recoveryDirectory.path) { return true }
        for directory in [dataDirectory, pendingDirectory, tombstoneDirectory] {
            do {
                if !((try fm.contentsOfDirectory(atPath: directory.path)).isEmpty) { return true }
            } catch {
                log.error("cannot inspect recovery evidence at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // An unreadable evidence directory is not proof of a new empty library.
                return true
            }
        }
        return false
    }

    private func decodeIndex(at url: URL, under base: URL? = nil) throws -> DecodedIndex {
        let data = try readProtectedData(at: url, under: base ?? root)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(IndexEnvelope.self, from: data) {
            return DecodedIndex(
                epoch: envelope.epoch,
                records: envelope.records,
                plaintextHash: ClipboardVault.plaintextHash(data)
            )
        }
        return DecodedIndex(
            epoch: 0,
            records: try decoder.decode([ClipRecord].self, from: data),
            plaintextHash: ClipboardVault.plaintextHash(data)
        )
    }

    private func readPendingRecords() -> [UUID: PendingRecord] {
        readJournal(directory: pendingDirectory, as: PendingRecord.self) { $0.record.id }
    }

    /// Every tombstone on disk, in either format, keyed by id. Where an id is named by
    /// more than one file — a batch clear after an individual deletion — the highest
    /// epoch wins, which is the only reading that cannot resurrect a later deletion.
    private func readTombstones() -> [UUID: Tombstone] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: tombstoneDirectory.path) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var values: [UUID: Tombstone] = [:]
        func record(id: UUID, epoch: UInt64) {
            if let existing = values[id], existing.epoch >= epoch { return }
            values[id] = Tombstone(epoch: epoch, id: id)
        }
        for name in names where (name as NSString).pathExtension == "json" {
            let url = tombstoneDirectory.appendingPathComponent(name)
            do {
                let data = try readProtectedData(at: url)
                if name.hasPrefix(Self.tombstoneBatchPrefix) {
                    let batch = try decoder.decode(TombstoneBatch.self, from: data)
                    for id in batch.ids { record(id: id, epoch: batch.epoch) }
                } else {
                    let single = try decoder.decode(Tombstone.self, from: data)
                    record(id: single.id, epoch: single.epoch)
                }
            } catch {
                log.error("clipboard journal is unreadable at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return values
    }

    /// The (id, epoch) pairs one tombstone file stands for, in either format.
    private func decodeTombstoneFile(named name: String) -> [(id: UUID, epoch: UInt64)]? {
        let url = tombstoneDirectory.appendingPathComponent(name)
        guard let data = try? readProtectedData(at: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if name.hasPrefix(Self.tombstoneBatchPrefix) {
            guard let batch = try? decoder.decode(TombstoneBatch.self, from: data) else {
                return nil
            }
            return batch.ids.map { (id: $0, epoch: batch.epoch) }
        }
        guard let single = try? decoder.decode(Tombstone.self, from: data) else { return nil }
        return [(id: single.id, epoch: single.epoch)]
    }

    private func readJournal<Value: Decodable>(
        directory: URL, as type: Value.Type, id: (Value) -> UUID
    ) -> [UUID: Value] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var values: [UUID: Value] = [:]
        for name in names where (name as NSString).pathExtension == "json" {
            let url = directory.appendingPathComponent(name)
            do {
                let value = try decoder.decode(Value.self, from: readProtectedData(at: url))
                values[id(value)] = value
            } catch {
                log.error("clipboard journal is unreadable at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return values
    }

    private func pendingPayloadIsValid(_ pending: PendingRecord) -> Bool {
        if pending.record.oversized { return true }
        guard let data = try? readProtectedData(at: payloadURL(pending.record.id)),
              let payload = ClipPayloadCoder.decode(data)
        else { return false }
        return ClipPayloadCoder.digest(payload) == pending.record.digest
    }

    private func makeRecoveryIncidentDirectory() -> URL? {
        let incident = recoveryDirectory.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try Self.createSecureDirectory(at: incident)
            return incident
        } catch {
            log.error("cannot create clipboard recovery incident: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func quarantine(_ url: URL, in incident: URL, category: String?) {
        let destinationDirectory = category.map {
            incident.appendingPathComponent($0, isDirectory: true)
        } ?? incident
        do {
            try Self.createSecureDirectory(at: destinationDirectory)
            var destination = destinationDirectory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = destinationDirectory.appendingPathComponent(
                    "\(UUID().uuidString)-\(url.lastPathComponent)"
                )
            }
            try FileManager.default.moveItem(at: url, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: destination.path
            )
            log.error("quarantined clipboard file at \(destination.path, privacy: .public)")
        } catch {
            log.error("cannot quarantine \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recoverablePayloads(excluding known: Set<UUID>) -> [RecoveredPayload] {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dataDirectory.path)
        } catch {
            log.error("cannot scan clipboard payloads for recovery: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var recovered: [RecoveredPayload] = []
        for name in names where (name as NSString).pathExtension == "plist" {
            let stem = (name as NSString).deletingPathExtension
            guard let id = UUID(uuidString: stem), !known.contains(id) else { continue }
            let url = dataDirectory.appendingPathComponent(name)
            do {
                let data = try readProtectedData(at: url)
                guard let payload = ClipPayloadCoder.decode(data) else {
                    log.error("payload is not decodable during recovery: \(url.path, privacy: .public)")
                    continue
                }
                let attributes = try fm.attributesOfItem(atPath: url.path)
                let createdAt = attributes[.modificationDate] as? Date ?? Date()
                recovered.append(RecoveredPayload(
                    id: id, createdAt: createdAt, payload: payload, pendingRecord: nil
                ))
            } catch {
                log.error("cannot inspect recovery payload \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return recovered
    }

    private func adoptLoadedIndex(_ load: IndexLoadResult) {
        let decoded = load.records
        let captured = records
        var mergedCount = 0

        if captured.isEmpty {
            records = decoded
            // The index is written newest-first, but `insertSorted` places rows by
            // binary search and a snapshot from another build — or a hand-edited one —
            // must not be trusted to be in order. One sort at launch makes the
            // precondition true instead of assumed.
            sortRecords()
            generation &+= 1
        } else {
            // Something was copied while the read was in flight, and it was recorded
            // under a brand-new id because the history it might already be in had not
            // arrived yet.
            //
            // Where the capture is genuinely new it simply joins the list. Where it
            // matches a record on disk by digest, the *disk* record wins: it owns the
            // identity everything else refers to — the paste queue holds its id, and its
            // pinned flag, source and thumbnail are things the fresh capture cannot know.
            // Only `createdAt` moves over, which is exactly the bump `insert` performs
            // when the same thing is copied twice. Keeping the capture instead would
            // strip the pin, orphan the disk record's files for `reconcileOrphans` to
            // delete, and let `queue.prune` drop the id the queue was holding.
            var merged = decoded
            var indexByDigest: [String: Int] = [:]
            for (index, record) in merged.enumerated() { indexByDigest[record.digest] = index }

            // The capture already wrote payload and search sidecars under its own id.
            // Those files belong to no record once the capture is discarded, so they go
            // now; the disk record's own files are untouched.
            var discarded: [UUID] = []
            var adoptedSearch: [(UUID, ClipSearchEntry)] = []

            for capture in captured {
                if let index = indexByDigest[capture.digest] {
                    merged[index].createdAt = capture.createdAt
                    if let entry = searchIndex[capture.id] {
                        adoptedSearch.append((merged[index].id, entry))
                    }
                    discarded.append(capture.id)
                } else {
                    indexByDigest[capture.digest] = merged.count
                    merged.append(capture)
                }
            }

            records = merged
            sortRecords()
            if !discarded.isEmpty { removeFiles(for: discarded) }
            // Re-hung after `removeFiles`, which clears the discarded id's entry: the
            // body is the same text either way, so the row stays searchable immediately
            // instead of waiting for the sidecar scan.
            for (id, entry) in adoptedSearch {
                searchIndex[id] = entry
                if let survivor = records.first(where: { $0.id == id }) {
                    invertedSearchIndex.upsert(record: survivor, entry: entry)
                }
            }
            mergedCount = captured.count
        }

        recoveryIncidentDirectory = load.incidentDirectory
        quarantineOrphans = load.requiresRecovery

        var recoveredCount = 0
        var liveIDs = Set(records.map(\.id))
        var liveDigests = Set(records.map(\.digest))
        var indexByID: [UUID: Int] = [:]
        for (index, record) in records.enumerated() { indexByID[record.id] = index }
        for recovered in load.recoveredPayloads {
            let digest = ClipPayloadCoder.digest(recovered.payload)
            if let index = indexByID[recovered.id] {
                guard records[index].digest != digest else { continue }
                let existing = records[index]
                var rebuilt = makeRecoveredRecord(recovered, digest: digest)
                rebuilt.createdAt = existing.createdAt
                rebuilt.sourceBundleID = existing.sourceBundleID
                rebuilt.sourceName = existing.sourceName
                rebuilt.pinned = existing.pinned
                rebuilt.pinnedRank = existing.pinnedRank
                liveDigests.remove(existing.digest)
                liveDigests.insert(digest)
                records[index] = rebuilt
                refreshRecoveredSearch(for: rebuilt, payload: recovered.payload)
                recoveredCount += 1
                continue
            }
            guard !liveIDs.contains(recovered.id) else { continue }
            guard !liveDigests.contains(digest) else { continue }
            let rebuilt = makeRecoveredRecord(recovered, digest: digest)
            records.append(rebuilt)
            refreshRecoveredSearch(for: rebuilt, payload: recovered.payload)
            indexByID[recovered.id] = records.count - 1
            liveIDs.insert(recovered.id)
            liveDigests.insert(digest)
            recoveredCount += 1
        }
        if recoveredCount > 0 { sortRecords() }

        // Before anything reads the band: the panel, a reorder and the next flush all
        // expect every pin to carry a rank, and this is the one moment a history written
        // by an older build passes through.
        let backfilled = backfillPinnedRanks()
        digestLock.lock()
        payloadDigests = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.digest) })
        digestLock.unlock()
        digestToID = Dictionary(records.map { ($0.digest, $0.id) }) { current, _ in current }

        let launchEpochAdvances = indexEpoch
        indexEpoch = load.epoch &+ launchEpochAdvances
        let mustSolidify = load.needsSynchronousCommit || mergedCount > 0
            || recoveredCount > 0 || backfilled
        if mustSolidify {
            indexEpoch &+= 1
            let snapshot = records
            let epoch = indexEpoch
            let committed = io.sync { writeIndexSnapshot(snapshot, epoch: epoch, token: nil) }
            if !committed {
                quarantineOrphans = true
                log.error("recovered clipboard index could not be synchronously solidified")
            }
        } else {
            let loadedEpoch = indexEpoch
            io.sync { lastCommittedEpoch = max(lastCommittedEpoch, loadedEpoch) }
        }

        isLoaded = true
        log.info("clipboard history loaded: \(self.records.count) entries")
        if mergedCount > 0 {
            log.info("index load merged with \(mergedCount) entries captured during launch")
        }

        // Saved filters are an independent encrypted sidecar, but still part of a fully
        // loaded store. Normal launches must adopt them just like recovery launches do.
        loadSmartFilters()

        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter() }

        // Strictly after the index, because it walks one sidecar file per record — and
        // strictly after the waiters, because the first sweep runs in one of them. Started
        // any earlier, the scan would capture ids that are about to be evicted and then
        // merge their text back in, leaving zombie entries in memory for the rest of the
        // session and rewriting sidecars for records that no longer exist.
        loadSearchIndex()
    }

    private func loadSmartFilters() {
        let url = smartFiltersURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            finishSmartFilterLoad(.empty)
            return
        }
        loadQueue.async { [weak self, log] in
            guard let self, self.vault.canDecrypt else { return }
            do {
                let decoded = try SmartFilterStore.decode(self.readProtectedData(at: url))
                DispatchQueue.main.async { self.finishSmartFilterLoad(decoded) }
            } catch {
                // Saved queries are derivative metadata. A malformed future/corrupt
                // version stays untouched on disk and cannot block clipboard history.
                log.error("saved filters could not be decoded: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self.finishSmartFilterLoad(.empty) }
            }
        }
    }

    private func finishSmartFilterLoad(_ loaded: SmartFilterStore) {
        guard !areSmartFiltersLoaded else { return }
        smartFilters = loaded
        areSmartFiltersLoaded = true
        let waiters = smartFilterLoadWaiters
        smartFilterLoadWaiters.removeAll()
        for waiter in waiters { waiter() }
    }

    private func makeRecoveredRecord(_ recovered: RecoveredPayload, digest: String) -> ClipRecord {
        let payload = recovered.payload
        let types = Set(payload.flatMap(\.keys))
        let kind: ClipKind
        if types.contains("public.file-url") {
            kind = .files
        } else if types.contains(NSPasteboard.PasteboardType.png.rawValue)
                    || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) {
            kind = .image
        } else if types.contains(NSPasteboard.PasteboardType.color.rawValue) {
            kind = .color
        } else {
            let text = ClipCapture.plainText(from: payload) ?? ""
            if ClipCapture.textKind(for: text) == .url {
                kind = .url
            } else if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
                        || types.contains(NSPasteboard.PasteboardType.html.rawValue) {
                kind = .richText
            } else {
                kind = .text
            }
        }

        var record = ClipRecord(
            id: recovered.id,
            createdAt: recovered.createdAt,
            kind: kind,
            preview: ClipCapture.makePreview(kind: kind, payload: payload),
            digest: digest,
            byteSize: ClipPayloadCoder.byteSize(payload),
            sourceBundleID: nil,
            sourceName: nil
        )
        if kind == .files { record.fileCount = ClipCapture.fileURLs(from: payload).count }
        if kind == .color { record.colorHex = ClipCapture.colorHex(from: payload) }
        if kind == .image, let image = ClipCapture.image(from: payload) {
            let size = image.representationPixelSize
            record.pixelWidth = size.width
            record.pixelHeight = size.height
            record.hasThumbnail = FileManager.default.fileExists(
                atPath: thumbnailURL(recovered.id).path
            )
        }
        if kind == .text || kind == .richText,
           let text = ClipCapture.plainText(from: payload) {
            record.contentTag = ClipCapture.contentTag(
                for: String(text.prefix(Self.tagSourceLimit))
            )
        }
        return record
    }

    private func refreshRecoveredSearch(for record: ClipRecord, payload: ClipPayload) {
        let url = searchTextURL(record.id)
        let data: Data?
        if let text = searchText(kind: record.kind, payload: payload),
           let entry = ClipSearch.makeEntry(text: text) {
            searchIndex[record.id] = entry
            invertedSearchIndex.upsert(record: record, entry: entry)
            data = Data(entry.text.utf8)
        } else {
            searchIndex[record.id] = nil
            invertedSearchIndex.remove(record.id)
            data = nil
        }
        scheduleSearchSegmentWrite(ClipSearchIndex.slot(for: record.id))

        io.async { [weak self, log] in
            guard let self, self.vault.isReady else { return }
            do {
                if let data {
                    try self.writeProtectedData(data, to: url)
                } else {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                }
            } catch {
                log.error("recovered search text write failed for \(record.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Search index

    /// The exact production cold-restore transition, kept internal so the memory gate
    /// can exercise this path rather than reimplementing a friendlier per-slot loop.
    /// Each materialized decoded segment is validated and immediately compacted into
    /// `candidate`; ARC releases it before the next slot. Returning nil releases the
    /// entire partial candidate before the caller starts a global rebuild.
    static func restorePersistedSearchIndex(
        recordsBySlot: [Int: [ClipRecord]], entries: [UUID: ClipSearchEntry],
        maximumResidentBytes: Int = ClipSearchIndex.maximumResidentBytes,
        readProtectedSegment: (Int) throws -> Data
    ) -> ClipSearchIndex? {
        var candidate = ClipSearchIndex.build(
            records: [], entries: [:], maximumResidentBytes: maximumResidentBytes
        )
        for slot in 0..<ClipSearchIndex.segmentCount {
            let expected = recordsBySlot[slot] ?? []
            guard !expected.isEmpty else { continue }
            let expectedByID = Dictionary(
                expected.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current }
            )
            guard expectedByID.count == expected.count,
                  expected.allSatisfy({
                      ClipSearchIndex.slot(for: $0.id) == slot && entries[$0.id] != nil
                  })
            else { return nil }
            let accepted = autoreleasepool { () -> Bool in
                guard let protected = try? readProtectedSegment(slot),
                      let segment = try? ClipSearchIndex.decodeSegment(
                          protected, expectedSlot: slot
                      ),
                      // A globally budgeted build may persist only a subset — including
                      // an empty subset — of the records assigned to an occupied slot.
                      // That is a valid accelerator because search fully verifies every
                      // unrepresented record. The inverse is never valid: an alien id or
                      // stale digest could suppress the real record from that fallback.
                      segment.documents.allSatisfy({ id, _ in
                          guard let record = expectedByID[id],
                                let entry = entries[id]
                          else { return false }
                          return segment.contains(
                              recordID: id, recordDigest: record.digest, entry: entry
                          )
                      })
                else { return false }
                do { try candidate.replaceSegment(segment); return true }
                catch { return false }
            }
            guard accepted else { return nil }
            // JSONDecoder necessarily creates one Data allocation per document filter.
            // `replaceSegment` has packed those bytes into the candidate; return the
            // just-released per-document allocator pages before decoding the next slot.
            _ = malloc_zone_pressure_relief(malloc_default_zone(), 0)
        }
        return candidate
    }

    /// Reconciles live records with a restored accelerator and returns only slots whose
    /// persisted representation actually changed. A record omitted by a budget-limited
    /// generation may still fail to fit after restore; repeatedly marking that unchanged
    /// omission dirty would rotate the AES-GCM ciphertext on every launch forever.
    static func reconcileRestoredSearchIndex(
        _ restored: ClipSearchIndex, records: [ClipRecord],
        entries: [UUID: ClipSearchEntry]
    ) -> (index: ClipSearchIndex, dirtySlots: Set<Int>) {
        var adopted = restored
        var dirtySlots = Set<Int>()
        var representedIDs = adopted.documentIDs
        for record in records {
            guard let entry = entries[record.id],
                  !adopted.contains(record: record, entry: entry)
            else { continue }
            let wasPresent = representedIDs.contains(record.id)
            adopted.upsert(record: record, entry: entry)
            let isPresent = adopted.contains(record: record, entry: entry)
            // A stale represented document must be removed from persistence even when
            // its replacement no longer fits. A never-represented document that still
            // does not fit changed nothing and therefore must not trigger a rewrite.
            if wasPresent || isPresent {
                dirtySlots.insert(ClipSearchIndex.slot(for: record.id))
            }
            if isPresent { representedIDs.insert(record.id) }
            else { representedIDs.remove(record.id) }
        }
        return (adopted, dirtySlots)
    }

    /// Reads the sidecar text for every record in the background, building it from the
    /// payload for anything recorded before this existed. Nothing waits on it: until it
    /// lands, `search` falls back to previews and source names, which is exactly what
    /// the previous version did — so a large history opens the panel just as fast.
    private func loadSearchIndex() {
        isInvertedSearchReady = false
        let recordSnapshot = records
        let ids = recordSnapshot.map(\.id)
        guard !ids.isEmpty else {
            invertedSearchIndex = .empty
            isInvertedSearchReady = true
            onSearchIndexLoaded?()
            return
        }
        // Bound URLs keep path construction independent from main-thread state. The
        // weak store is retained only while an authenticated read/write is in progress.
        let searchDir = searchDirectory
        let dataDir = dataDirectory
        let textURL = { (id: UUID) in searchDir.appendingPathComponent("\(id.uuidString).txt") }
        let payloadURL = { (id: UUID) in dataDir.appendingPathComponent("\(id.uuidString).plist") }
        let segmentURL = { (slot: Int) in
            self.searchIndexDirectory.appendingPathComponent(
                String(format: "segment-%02d.json", slot)
            )
        }

        loadQueue.async { [weak self, log] in
            guard let self, self.vault.isReady else { return }
            var loaded: [UUID: ClipSearchEntry] = [:]
            var rebuilt: [(UUID, String)] = []

            for id in ids {
                if let data = try? self.readProtectedData(at: textURL(id)),
                   let text = String(data: data, encoding: .utf8),
                   let entry = ClipSearch.makeEntry(text: text) {
                    loaded[id] = entry
                    continue
                }
                // Pre-upgrade entry. Plain text only — unpacking RTF or HTML goes
                // through AppKit, which is not allowed here.
                guard let data = try? self.readProtectedData(at: payloadURL(id)),
                      let payload = ClipPayloadCoder.decode(data),
                      let text = ClipCapture.plainTextOnly(from: payload),
                      let entry = ClipSearch.makeEntry(text: text)
                else { continue }
                loaded[id] = entry
                rebuilt.append((id, entry.text))
            }

            for (id, text) in rebuilt {
                do {
                    try self.writeProtectedData(Data(text.utf8), to: textURL(id))
                } catch {
                    log.error("search text backfill failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if !rebuilt.isEmpty {
                log.info("search index backfilled for \(rebuilt.count) older entries")
            }

            var inverted = ClipSearchIndex.empty
            var rebuiltSlots = Set<Int>()
            let recordsBySlot = Dictionary(grouping: recordSnapshot.filter {
                loaded[$0.id] != nil
            }, by: { ClipSearchIndex.slot(for: $0.id) })
            if let restored = Self.restorePersistedSearchIndex(
                recordsBySlot: recordsBySlot, entries: loaded,
                readProtectedSegment: { try self.readProtectedData(at: segmentURL($0)) }
            ) {
                inverted = restored
            } else {
                // `restorePersistedSearchIndex` owns its partial candidate locally. It
                // has been released before this global rebuild begins, so decoded 12KiB
                // document filters never coexist with the replacement index.
                let searchableRecords = recordSnapshot.filter { loaded[$0.id] != nil }
                inverted = ClipSearchIndex.build(records: searchableRecords, entries: loaded)
                // The global allocator distributes its fixed budget across every slot;
                // its decisions differ from any previously decoded segment, so persist
                // one coherent generation rather than a mixture of budget epochs.
                rebuiltSlots.formUnion(recordsBySlot.keys)
            }

            DispatchQueue.main.async {
                // A record can be evicted while the scan is in flight — the hourly sweep,
                // or a capture that pushes the history over its cap. Merging its text back
                // in would leave a body of up to 32KB in memory, attached to an id nothing
                // can ever show again, until the process quits.
                let live = Set(self.records.map(\.id))
                let surviving = loaded.filter { live.contains($0.key) }
                // Anything copied while this ran was indexed from a live payload and is
                // therefore better than what came off disk; keep it.
                self.searchIndex.merge(surviving) { current, _ in current }
                var adopted = inverted
                var dirtySlots = rebuiltSlots
                for id in adopted.documentIDs where !live.contains(id) {
                    adopted.remove(id)
                    dirtySlots.insert(ClipSearchIndex.slot(for: id))
                }
                let reconciled = Self.reconcileRestoredSearchIndex(
                    adopted, records: self.records, entries: self.searchIndex
                )
                adopted = reconciled.index
                dirtySlots.formUnion(reconciled.dirtySlots)
                self.invertedSearchIndex = adopted
                self.isInvertedSearchReady = true
                self.scheduleSearchSegmentWrites(dirtySlots)
                self.log.info("search index ready: \(self.searchIndex.count) entries")
                self.onSearchIndexLoaded?()
            }
        }
    }

    private func scheduleSearchSegmentWrite(_ slot: Int) {
        scheduleSearchSegmentWrites([slot])
    }

    private func scheduleSearchSegmentWrites(_ slots: Set<Int>) {
        guard vault.isReady, !slots.isEmpty else { return }
        // Keep one newest COW snapshot and one worker rather than enqueueing an encoding
        // closure per capture/edit. A 10K import can otherwise spend minutes encoding
        // snapshots that are obsolete before their write begins.
        let shouldSchedule = searchSegmentEpochLock.withLock { () -> Bool in
            for slot in slots {
                let epoch = searchSegmentEpochs[slot, default: 0] &+ 1
                searchSegmentEpochs[slot] = epoch
                pendingSearchSegmentSlots.insert(slot)
            }
            pendingSearchSegmentIndex = invertedSearchIndex
            guard !isSearchSegmentWorkerScheduled else { return false }
            isSearchSegmentWorkerScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        io.async { [weak self, log] in
            guard let self, self.vault.isReady else { return }
            while true {
                let batch = self.searchSegmentEpochLock.withLock {
                    () -> (ClipSearchIndex, [(slot: Int, epoch: UInt64, url: URL)])? in
                    guard let snapshot = self.pendingSearchSegmentIndex,
                          !self.pendingSearchSegmentSlots.isEmpty
                    else {
                        self.isSearchSegmentWorkerScheduled = false
                        return nil
                    }
                    let writes = self.pendingSearchSegmentSlots.sorted().map { slot in
                        (
                            slot: slot,
                            epoch: self.searchSegmentEpochs[slot, default: 0],
                            url: self.searchSegmentURL(slot)
                        )
                    }
                    self.pendingSearchSegmentSlots.removeAll(keepingCapacity: true)
                    self.pendingSearchSegmentIndex = nil
                    return (snapshot, writes)
                }
                guard let (indexSnapshot, writes) = batch else { return }
                for write in writes {
                    let isCurrent = self.searchSegmentEpochLock.withLock {
                        self.searchSegmentEpochs[write.slot] == write.epoch
                    }
                    guard isCurrent else { continue }
                    let data: Data
                    do { data = try indexSnapshot.encodedSegment(slot: write.slot) }
                    catch {
                        log.error("search segment \(write.slot) could not be encoded")
                        continue
                    }
                    let stillCurrent = self.searchSegmentEpochLock.withLock {
                        self.searchSegmentEpochs[write.slot] == write.epoch
                    }
                    guard stillCurrent else { continue }
                    do { try self.writeProtectedData(data, to: write.url) }
                    catch {
                        log.error("search segment write failed for \(write.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// The body a record is searched by. Called on the main thread from `insert`, which
    /// is why it can afford `plainText(from:)` and its AppKit-backed RTF/HTML fallback.
    private func searchText(kind: ClipKind, payload: ClipPayload) -> String? {
        switch kind {
        case .image:
            return nil
        case .files:
            let paths = ClipCapture.fileURLs(from: payload).map(\.path)
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        case .text, .richText, .url, .color:
            return ClipCapture.plainText(from: payload)
        }
    }

    /// Debounced: a burst of copies produces one write, not one per copy.
    ///
    /// No write of any kind happens before the index has been read back. `records` then
    /// holds at most what was captured in the launch window, and writing that out would
    /// replace the entire history on disk with a single row — after which the next
    /// launch's `reconcileOrphans` deletes every payload behind the rows that vanished.
    /// Nothing is lost by skipping: `adoptLoadedIndex` merges those captures into the
    /// loaded index and flushes once, afterwards.
    private func scheduleFlush(immediate: Bool = false) {
        generation &+= 1
        indexEpoch &+= 1
        flushToken?.cancel()
        flushToken = nil
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard isLoaded, vault.isReady else { return }
        let snapshot = records
        let epoch = indexEpoch
        let token = FlushToken()
        let item = DispatchWorkItem { [weak self] in
            guard !token.isCancelled, let self else { return }
            _ = self.writeIndexSnapshot(snapshot, epoch: epoch, token: token)
        }
        flushToken = token
        flushWorkItem = item
        // `immediate` still does not block the main thread — it only drops the debounce,
        // so the snapshot reaches disk in milliseconds instead of after 0.6 idle seconds.
        // See `persistTombstones` for why a batch deletion cannot afford the wait.
        if immediate { io.async(execute: item) }
        else { io.asyncAfter(deadline: .now() + 0.6, execute: item) }
    }

    /// Writes the index immediately. Called on quit, where a debounced write would be
    /// cancelled by the process going away.
    ///
    /// Guarded like `scheduleFlush`, and for a case that is anything but theoretical:
    /// quitting in the first moments after launch used to run this against an empty
    /// `records`, truncate index.json, and take the whole history's payloads with it on
    /// the next start. Before the load there is by definition nothing to save.
    @discardableResult
    func flushNow() -> Bool {
        flushToken?.cancel()
        flushToken = nil
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard isLoaded, vault.isReady else {
            log.info("index flush skipped: the history has not been read back yet")
            return false
        }
        let snapshot = records
        // All item files use the same serial queue. A synchronous final index therefore
        // cannot publish a row before its payload, and no older payload write can land
        // after this snapshot has been committed.
        let epoch = indexEpoch
        return io.sync { writeIndexSnapshot(snapshot, epoch: epoch, token: nil) }
    }

    /// Writes the recovery copy first and the primary second. Either file is always an
    /// atomic old-or-new snapshot; after a crash at least one complete snapshot remains.
    /// Call only from `io`, which serialises this with every item-file mutation.
    private func writeIndexSnapshot(
        _ snapshot: [ClipRecord], epoch: UInt64, token: FlushToken?
    ) -> Bool {
        guard vault.isReady else { return false }
        guard epoch >= lastCommittedEpoch else {
            log.error("refusing stale index epoch \(epoch); committed epoch is \(self.lastCommittedEpoch)")
            return false
        }
        let snapshotIDs = Set(snapshot.filter { !$0.oversized }.map(\.id))
        let failed = snapshotIDs.intersection(failedPayloadIDs)
        guard failed.isEmpty else {
            log.error("index commit refused because \(failed.count) payload writes failed")
            return false
        }
        guard token?.isCancelled != true else { return false }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // No `.prettyPrinted`: the bytes are sealed the moment they leave here, so the
        // indentation was paid for on every commit and read by nobody. `decodeIndex`
        // goes through JSONDecoder and `plaintextHash` hashes whatever was written, so
        // neither depends on the layout — including for an index written by an older
        // build, whose own bytes and own recorded hash still agree with each other.
        let data: Data
        do {
            data = try encoder.encode(IndexEnvelope(epoch: epoch, records: snapshot))
        } catch {
            log.error("index encoding failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Crash-consistent anti-replay order: encrypted staging is durable before the
        // trusted pending high-water advances. A restart can finish this exact snapshot;
        // it never accepts the previously committed generation as current.
        do {
            try writeProtectedData(data, to: indexTransactionURL)
            try vault.beginIndexCommit(epoch: epoch, plaintext: data)
        } catch {
            log.error("index trusted staging failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        var backupSucceeded = false
        do {
            try writeProtectedData(data, to: backupIndexURL)
            backupSucceeded = true
        } catch {
            log.error("index backup write failed: \(error.localizedDescription, privacy: .public)")
        }

        guard token?.isCancelled != true else { return false }
        do {
            try writeProtectedData(data, to: indexURL)
            guard backupSucceeded else { return false }
            try vault.completeIndexCommit(epoch: epoch, plaintext: data)
            lastCommittedEpoch = epoch
            cleanCommittedJournals(snapshot: snapshot, epoch: epoch)
            try? FileManager.default.removeItem(at: indexTransactionURL)
            log.info("index committed: \(snapshot.count) entries")
            return true
        } catch {
            log.error("index primary write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func cleanCommittedJournals(snapshot: [ClipRecord], epoch: UInt64) {
        let fm = FileManager.default
        let records = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })

        // Driven by the directory, not by the snapshot. A committed history has a
        // pending journal for the handful of rows written since the last flush, so
        // asking the filesystem for every record's journal meant one failing open per
        // record per commit — a thousand of them for the two that existed. The
        // tombstone half below has always been written this way.
        if let names = try? fm.contentsOfDirectory(atPath: pendingDirectory.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for name in names where (name as NSString).pathExtension == "json" {
                let stem = (name as NSString).deletingPathExtension
                guard let id = UUID(uuidString: stem), let record = records[id] else { continue }
                let url = pendingDirectory.appendingPathComponent(name)
                guard let data = try? readProtectedData(at: url),
                      let pending = try? decoder.decode(PendingRecord.self, from: data),
                      pending.epoch <= epoch, pending.record.digest == record.digest
                else { continue }
                try? fm.removeItem(at: url)
            }
        }

        guard let names = try? fm.contentsOfDirectory(atPath: tombstoneDirectory.path) else { return }
        for name in names where (name as NSString).pathExtension == "json" {
            guard let entries = decodeTombstoneFile(named: name) else { continue }
            // A batch file is the proof for every id it names, so it may only be dropped
            // once every one of them has individually finished with it. Each id is judged
            // by exactly the rule the per-id file was judged by before.
            let retired = !entries.isEmpty && entries.allSatisfy { entry in
                if records[entry.id] != nil { return epoch > entry.epoch }
                return !fm.fileExists(atPath: payloadURL(entry.id).path)
                    && !fm.fileExists(atPath: pendingURL(entry.id).path)
            }
            guard retired else { continue }
            try? fm.removeItem(at: tombstoneDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Insert

    struct PreparedImage {
        var pixelWidth: Int
        var pixelHeight: Int
        var thumbnailData: Data?
    }

    /// Immutable capture work prepared away from the main thread. Live clipboard
    /// insertion consumes this instead of hashing, parsing rich text, decoding an image,
    /// creating a thumbnail, or building a search entry while UI state is being mutated.
    struct CapturePreparation {
        var digest: String
        var preview: String
        var searchEntry: ClipSearchEntry?
        var contentTag: ClipContentTag?
        var fileCount: Int?
        var colorHex: String?
        var image: PreparedImage?
    }

    static func prepareCapturedPayload(
        _ payload: ClipPayload, kind: ClipKind,
        analysis: ClipCapture.PayloadAnalysis
    ) -> CapturePreparation {
        let fileURLs = kind == .files ? ClipCapture.fileURLs(from: payload) : []
        let colorHex = kind == .color ? ClipCapture.colorHex(from: payload) : nil
        let body: String?
        switch kind {
        case .image:
            body = nil
        case .files:
            let paths = fileURLs.map(\.path)
            body = paths.isEmpty ? nil : paths.joined(separator: "\n")
        case .text, .richText, .url, .color:
            body = analysis.plainText
        }

        let preview: String
        switch kind {
        case .files:
            let names = fileURLs.map(\.lastPathComponent)
            if names.isEmpty { preview = "文件" }
            else { preview = names.count == 1 ? names[0] : "\(names[0]) 等 \(names.count) 个文件" }
        case .image:
            preview = "图片"
        case .color:
            preview = colorHex ?? analysis.plainText ?? "颜色"
        case .text, .richText, .url:
            let collapsed = ClipCapture.collapsedPreview(analysis.plainText ?? "")
            preview = collapsed.isEmpty ? "（空白内容）" : collapsed
        }

        let contentTag: ClipContentTag?
        if kind == .text || kind == .richText {
            contentTag = ClipCapture.contentTag(
                for: String((body ?? preview).prefix(Self.tagSourceLimit))
            )
        } else {
            contentTag = nil
        }

        return CapturePreparation(
            digest: analysis.digest,
            preview: preview,
            searchEntry: body.flatMap { ClipSearch.makeEntry(text: $0) },
            contentTag: contentTag,
            fileCount: kind == .files ? fileURLs.count : nil,
            colorHex: colorHex,
            image: kind == .image ? prepareImage(payload) : nil
        )
    }

    /// ImageIO is thread-safe and avoids the AppKit drawing stack used by the legacy
    /// synchronous insertion path. The source bytes remain bounded by capture options.
    private static func prepareImage(_ payload: ClipPayload) -> PreparedImage? {
        let data = payload.lazy.compactMap { item in
            item[NSPasteboard.PasteboardType.png.rawValue]
                ?? item[NSPasteboard.PasteboardType.tiff.rawValue]
        }.first
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 720,
        ]
        var thumbnailData: Data?
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) {
            let destinationData = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(
                destinationData, NSPasteboard.PasteboardType.png.rawValue as CFString, 1, nil
            ) {
                CGImageDestinationAddImage(destination, thumbnail, nil)
                if CGImageDestinationFinalize(destination) {
                    thumbnailData = destinationData as Data
                }
            }
        }
        return PreparedImage(
            pixelWidth: width, pixelHeight: height, thumbnailData: thumbnailData
        )
    }

    struct Insertion {
        var payload: ClipPayload
        var kind: ClipKind
        var oversized: Bool
        var byteSize: Int
        var sourceBundleID: String?
        var sourceName: String?
        var prepared: CapturePreparation? = nil
        var sensitivity: ClipSensitivity? = nil
        var expiry: Date? = nil
        var oneTime: Bool = false
    }

    /// Adds a capture, or bumps the existing entry if the same thing was copied again.
    /// Returns the record that ended up at the top.
    @discardableResult
    func insert(_ insertion: Insertion) -> ClipRecord {
        let digest = insertion.prepared?.digest ?? ClipPayloadCoder.digest(insertion.payload)
        guard vault.isReady else {
            let reason: String
            if case let .readOnlyRecovery(value) = vault.state { reason = value.rawValue }
            else { reason = ClipboardVaultRecoveryReason.keychainUnavailable.rawValue }
            log.error("clipboard capture rejected while vault is in read-only recovery reason=\(reason, privacy: .public)")
            return ClipRecord(
                id: UUID(),
                createdAt: Date(),
                kind: insertion.kind,
                preview: insertion.prepared?.preview
                    ?? ClipCapture.makePreview(kind: insertion.kind, payload: insertion.payload),
                digest: digest,
                byteSize: insertion.byteSize,
                sourceBundleID: insertion.sourceBundleID,
                sourceName: insertion.sourceName,
                sensitivity: insertion.sensitivity,
                expiry: insertion.expiry,
                oneTime: insertion.oneTime,
                oversized: insertion.oversized
            )
        }

        // Re-copying something already in the history should move it up, not add a
        // second identical row. Pinned state and the original source survive the bump.
        if let existingID = digestToID[digest],
           let existing = records.firstIndex(where: { $0.id == existingID }),
           records[existing].digest == digest {
            var record = records[existing]
            record.createdAt = Date()
            // Privacy metadata describes this capture, not the stable digest. Explicitly
            // overwrite all three values so a later ordinary copy cannot retain a stale
            // password/OTP policy from an earlier capture of identical bytes.
            record.sensitivity = insertion.sensitivity
            record.expiry = insertion.expiry
            record.oneTime = insertion.oneTime
            records.remove(at: existing)
            insertSorted(record)
            scheduleFlush()
            log.info("re-copy of an existing entry; bumped \(record.id.uuidString, privacy: .public) to the top")
            return record
        }

        let id = UUID()
        var record = ClipRecord(
            id: id,
            createdAt: Date(),
            kind: insertion.kind,
            preview: insertion.prepared?.preview
                ?? ClipCapture.makePreview(kind: insertion.kind, payload: insertion.payload),
            digest: digest,
            byteSize: insertion.byteSize,
            sourceBundleID: insertion.sourceBundleID,
            sourceName: insertion.sourceName,
            sensitivity: insertion.sensitivity,
            expiry: insertion.expiry,
            oneTime: insertion.oneTime,
            oversized: insertion.oversized
        )

        if let prepared = insertion.prepared {
            record.fileCount = prepared.fileCount
            record.colorHex = prepared.colorHex
            record.contentTag = prepared.contentTag
        } else if insertion.kind == .files {
            record.fileCount = ClipCapture.fileURLs(from: insertion.payload).count
        }

        // Resolved once, here, rather than on every redraw: unarchiving an NSColor is
        // not expensive, but the payload it lives in is a separate file on disk.
        if insertion.prepared == nil, insertion.kind == .color {
            record.colorHex = ClipCapture.colorHex(from: insertion.payload)
        }

        var thumbnailData: Data?
        if let preparedImage = insertion.prepared?.image {
            record.pixelWidth = preparedImage.pixelWidth
            record.pixelHeight = preparedImage.pixelHeight
            thumbnailData = preparedImage.thumbnailData
            record.hasThumbnail = thumbnailData != nil
        } else if insertion.prepared == nil, insertion.kind == .image,
                  let image = ClipCapture.image(from: insertion.payload) {
            let size = image.representationPixelSize
            record.pixelWidth = size.width
            record.pixelHeight = size.height
            // Sized for the panel's preview pane, not the 34pt row — a thumbnail that
            // only suits the row gets visibly upscaled the moment it is selected.
            if let data = image.downscaledPNG(maxDimension: 720) {
                thumbnailData = data
                record.hasThumbnail = true
            }
        }

        // Lifted above the insert because the content tag is derived from the same body,
        // and the record has to carry it before it goes into the list.
        let body = insertion.prepared == nil
            ? searchText(kind: insertion.kind, payload: insertion.payload) : nil

        // Only where the entry *is* text. A file row's body is a column of paths and
        // would tag itself 路径 for saying what its icon already says, and an image has
        // no characters to read at all.
        if insertion.prepared == nil
            && (insertion.kind == .text || insertion.kind == .richText) {
            let source = body ?? record.preview
            record.contentTag = ClipCapture.contentTag(for: String(source.prefix(Self.tagSourceLimit)))
        }

        insertSorted(record)

        // Indexed even when the payload is over the cap: the text is a few kilobytes at
        // most, and being able to find the thing you copied is half of why the row is
        // still in the history at all.
        var searchTextData: Data?
        var insertedSearchEntry: ClipSearchEntry?
        if let entry = insertion.prepared?.searchEntry {
            searchIndex[id] = entry
            searchTextData = Data(entry.text.utf8)
            insertedSearchEntry = entry
        } else if let text = body, let entry = ClipSearch.makeEntry(text: text) {
            searchIndex[id] = entry
            searchTextData = Data(entry.text.utf8)
            insertedSearchEntry = entry
        }
        if let insertedSearchEntry {
            invertedSearchIndex.upsert(record: record, entry: insertedSearchEntry)
            scheduleSearchSegmentWrite(ClipSearchIndex.slot(for: id))
        }

        let payload = insertion.payload
        let payloadURL = payloadURL(id)
        let thumbURL = thumbnailURL(id)
        let searchURL = searchTextURL(id)
        let pendingURL = pendingURL(id)
        let pendingData = encodeJournal(PendingRecord(epoch: indexEpoch &+ 1, record: record))
        io.async { [weak self, log] in
            guard let self else { return }
            let payloadData = record.oversized ? nil : ClipPayloadCoder.encode(payload)
            if payloadData == nil, !record.oversized {
                log.error("payload could not be serialised for \(id.uuidString, privacy: .public) — the entry will not be pastable")
            }
            // A failed payload write leaves an index entry that pastes nothing, which
            // is exactly the kind of silent failure that is impossible to diagnose
            // later without a line in the log.
            var payloadSucceeded = record.oversized
            if let payloadData {
                do {
                    try self.writeProtectedData(payloadData, to: payloadURL)
                    payloadSucceeded = true
                } catch {
                    self.failedPayloadIDs.insert(id)
                    log.error("payload write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            guard payloadSucceeded, let pendingData else {
                self.failedPayloadIDs.insert(id)
                return
            }
            do {
                try self.writeProtectedData(pendingData, to: pendingURL)
                self.failedPayloadIDs.remove(id)
            } catch {
                self.failedPayloadIDs.insert(id)
                log.error("pending payload journal failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            if let thumbnailData {
                do {
                    try self.writeProtectedData(thumbnailData, to: thumbURL)
                } catch {
                    log.error("thumbnail write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if let searchTextData {
                // Losing this only costs full-text search for one entry, so it is worth
                // a log line but never worth failing the capture over.
                do {
                    try self.writeProtectedData(searchTextData, to: searchURL)
                } catch {
                    log.error("search text write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        log.info("recorded \(insertion.kind.rawValue, privacy: .public) entry, \(insertion.byteSize) bytes, from \(insertion.sourceName ?? "unknown", privacy: .public)")

        sweep()
        scheduleFlush()
        return record
    }

    /// Compare-and-swap seam for a classifier that finishes after insertion. The
    /// expected digest prevents a stale decision from attaching secret metadata to an
    /// entry that kept its UUID but was edited in the meantime.
    @discardableResult
    func updatePrivacyMetadata(
        id: UUID, expectedDigest: String, sensitivity: ClipSensitivity?,
        expiry: Date?, oneTime: Bool
    ) -> ClipRecord? {
        guard vault.isReady,
              let index = records.firstIndex(where: { $0.id == id }),
              records[index].digest == expectedDigest
        else { return nil }
        var record = records[index]
        record.sensitivity = sensitivity
        record.expiry = expiry
        record.oneTime = oneTime
        records[index] = record
        scheduleFlush()
        return record
    }

    private func encodeJournal<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(value)
        } catch {
            log.error("clipboard journal encoding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pinned entries float to the top; everything else is newest-first.
    ///
    /// The list is already in order — every caller either appends to a sorted array or
    /// removes one row from it first — so the new row's place is a binary search and one
    /// `memmove`, not a fresh n log n sort of the whole history on every capture.
    /// `sortRecords` stays for the paths that really do arrive unordered: the index
    /// load, recovery, rank backfill and undo.
    private func insertSorted(_ record: ClipRecord) {
        var low = 0
        var high = records.count
        while low < high {
            let middle = low + (high - low) / 2
            if Self.isOrderedBefore(records[middle], record) { low = middle + 1 }
            else { high = middle }
        }
        records.insert(record, at: low)
        digestLock.lock()
        payloadDigests[record.id] = record.digest
        digestLock.unlock()
        digestToID[record.digest] = record.id
    }

    /// Pinned first, then the band's own order, then the clock.
    ///
    /// The middle rule is what makes 收藏 rearrangeable: inside the band a rank decides,
    /// and `togglePin` hands one out to every pin, so in a settled history the fallback to
    /// `createdAt` is only ever reached between two unpinned rows. It still has to be
    /// there — an index read back from before ranks existed has none until
    /// `backfillPinnedRanks` runs, and an undone deletion can put a rank back that another
    /// pin has since been given.
    private func sortRecords() {
        records.sort(by: Self.isOrderedBefore)
    }

    /// The one definition of history order, shared by the full sort and by the binary
    /// placement in `insertSorted` — they cannot be allowed to disagree.
    private static func isOrderedBefore(_ lhs: ClipRecord, _ rhs: ClipRecord) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        if lhs.pinned {
            switch (lhs.pinnedRank, rhs.pinnedRank) {
            case let (left?, right?) where left != right: return left < right
            // A pin with no rank yet goes behind the ones that have one, which is
            // also the order `backfillPinnedRanks` then writes down.
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
        }
        return lhs.createdAt > rhs.createdAt
    }

    /// The highest rank in the band, or -1 when nothing is pinned.
    private var highestPinnedRank: Int {
        records.reduce(-1) { max($0, $1.pinnedRank ?? -1) }
    }

    /// Gives every pinned row a rank, once, for a history written before ranks existed.
    ///
    /// The numbers go out in the order those rows were already being shown in, so the
    /// first launch after the upgrade looks exactly like the last one before it — and from
    /// then on the band has an order of its own that re-copying cannot disturb. Returns
    /// whether anything changed, because the caller owes the disk a write if it did.
    @discardableResult
    private func backfillPinnedRanks() -> Bool {
        guard records.contains(where: { $0.pinned && $0.pinnedRank == nil }) else { return false }
        sortRecords()
        var next = 0
        for index in records.indices where records[index].pinned {
            records[index].pinnedRank = next
            next += 1
        }
        log.info("assigned ranks to \(next) pinned entries that had none")
        return true
    }

    /// Rewrites the 收藏 band as 0..n in the order it is being shown in, closing any gaps
    /// and breaking any ties. For the one caller that can produce both: `undoLastDelete`.
    ///
    /// `reclaimed` is the ids coming back from the undo buffer. They keep the places they
    /// held, and a live pin holding one of those numbers is the one that moves — see
    /// `place` below.
    private func normalizePinnedRanks(reclaimedBy reclaimed: Set<UUID>) {
        var band = records.filter(\.pinned)
        guard !band.isEmpty else { return }

        // The places the restored rows are bringing back with them.
        let reclaimedRanks = Set(
            band.compactMap { reclaimed.contains($0.id) ? $0.pinnedRank : nil }
        )

        /// Where a row belongs in the band, before the numbers are closed up.
        ///
        /// A live pin holding a reclaimed number was handed it by `togglePin` while the
        /// band was missing the deleted rows, so the number is not a place it earned — and
        /// the one thing actually known about that pin is that it was made more recently
        /// than anything the batch is putting back. It goes to the end, which is where
        /// `togglePin` would have put it had the deletion never happened. An unranked pin
        /// — a history from before ranks existed — goes there too, the same place
        /// `sortRecords` puts it.
        func place(_ record: ClipRecord) -> Int {
            guard let rank = record.pinnedRank else { return .max }
            if !reclaimed.contains(record.id), reclaimedRanks.contains(rank) { return .max }
            return rank
        }

        band.sort { lhs, rhs in
            let left = place(lhs)
            let right = place(rhs)
            if left != right { return left < right }
            // Two rows sent to the end, or two carrying no rank at all: there is nothing
            // left to order them by but the clock, which is `sortRecords`' own last resort.
            return lhs.createdAt > rhs.createdAt
        }

        var ranks: [UUID: Int] = [:]
        for (rank, record) in band.enumerated() { ranks[record.id] = rank }
        for index in records.indices where records[index].pinned {
            records[index].pinnedRank = ranks[records[index].id]
        }
        sortRecords()
    }

    // MARK: - Read

    func record(id: UUID) -> ClipRecord? {
        records.first { $0.id == id }
    }

    /// The encrypted payload's physical location. Kept for file-existence diagnostics
    /// and tests that inject missing-file failures; content readers must use
    /// `payloadData(for:)` so authentication and read-only transitions cannot be skipped.
    func payloadLocation(for id: UUID) -> URL { payloadURL(id) }

    /// The authenticated bytes *and* the payload they parse to, decoded once.
    ///
    /// Verifying the index digest requires a decoded payload, and `payload(for:)` then
    /// wanted one too — so every paste of a screenshot ran the property-list parser over
    /// the same tens of megabytes twice. Both entry points come through here now; the
    /// digest check itself is unchanged. Touches no main-thread store state and never
    /// stages plaintext on disk, so preview, drag and interoperability may call it from
    /// their own queues.
    private func authenticatedPayload(for id: UUID) -> (data: Data, payload: ClipPayload)? {
        do {
            let data = try readProtectedData(at: payloadURL(id))
            digestLock.lock()
            let expectedDigest = payloadDigests[id]
            digestLock.unlock()
            guard let expectedDigest,
                  let payload = ClipPayloadCoder.decode(data),
                  ClipPayloadCoder.digest(payload) == expectedDigest else {
                log.error("payload bytes for \(id.uuidString, privacy: .public) disagree with the authenticated index digest")
                return nil
            }
            return (data, payload)
        } catch {
            log.error("payload bytes for \(id.uuidString, privacy: .public) could not be authenticated: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Thread-safe authenticated bytes for preview, drag and interoperability pipelines.
    func payloadData(for id: UUID) -> Data? {
        authenticatedPayload(for: id)?.data
    }

    func payload(for id: UUID) -> ClipPayload? {
        guard let authenticated = authenticatedPayload(for: id) else {
            log.error("payload for \(id.uuidString, privacy: .public) is not a readable plist")
            return nil
        }
        return authenticated.payload
    }

    /// Authenticated compressed thumbnail bytes for the preview pipeline. The store does
    /// not decode or cache pixels: `ClipPreviewCache` is the single budget owner, so its
    /// 32 MB ceiling and panel-close purge are real rather than sitting above a second,
    /// count-only cache that can retain hundreds of megabytes.
    func thumbnailData(for record: ClipRecord) -> Data? {
        guard record.hasThumbnail else { return nil }
        return try? readProtectedData(at: thumbnailURL(record.id))
    }

    /// Compatibility reader for non-panel callers and storage tests. Intentionally has
    /// no cache; production previews use `thumbnailData(for:)` and account decoded pixels
    /// in `ClipPreviewCache`.
    func thumbnail(for record: ClipRecord) -> NSImage? {
        thumbnailData(for: record).flatMap(NSImage.init(data:))
    }

    /// Records and text index together, for a caller that wants to run the scan off the
    /// main thread. Must be taken here, on the main thread; both halves are
    /// copy-on-write, so the hand-off is two retains and never a deep copy.
    func searchSnapshot(queuedIDs: Set<UUID> = []) -> ClipSearchSnapshot {
        ClipSearchSnapshot(
            records: records, index: searchIndex,
            invertedIndex: isInvertedSearchReady ? invertedSearchIndex : nil,
            queuedIDs: queuedIDs
        )
    }

    /// Kept synchronous — callers that only ever filter a short list, and the tests, do
    /// not need the ceremony. The panel goes through `searchSnapshot()` instead so a
    /// full-text scan cannot stutter typing.
    func search(_ query: String, kind: ClipKind?, pinnedOnly: Bool) -> [ClipRecord] {
        guard var parsed = try? ClipQueryParser.parse(query) else { return [] }
        if let kind { parsed.kinds.insert(kind) }
        if pinnedOnly { parsed.pinned = true }
        return ClipSearch.run(ClipSearchRequest(query: parsed), in: searchSnapshot()).records
    }

    /// Cancels the previous backend query before scheduling this one. The token is
    /// checked while candidates and records are walked; stale keystrokes therefore do
    /// not consume a worker or race a newer result into the panel.
    @discardableResult
    func searchAsync(
        _ rawQuery: String, queuedIDs: Set<UUID> = [],
        onStarted: (() -> Void)? = nil,
        completion: @escaping (Result<ClipSearchOutcome, ClipQueryParseError>) -> Void
    ) -> ClipSearchCancellationToken? {
        let parsed: ClipQuery
        do { parsed = try ClipQueryParser.parse(rawQuery) }
        catch let error as ClipQueryParseError {
            activeSearchToken?.cancel()
            activeSearchToken = nil
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        } catch {
            let issue = ClipQueryParseError(position: 0, message: error.localizedDescription)
            DispatchQueue.main.async { completion(.failure(issue)) }
            return nil
        }
        activeSearchToken?.cancel()
        let token = ClipSearchCancellationToken()
        activeSearchToken = token
        let snapshot = searchSnapshot(queuedIDs: queuedIDs)
        searchQueryQueue.async {
            onStarted?()
            let outcome = ClipSearch.run(
                ClipSearchRequest(query: parsed, cancellation: token), in: snapshot
            )
            guard !outcome.cancelled else { return }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completion(.success(outcome))
            }
        }
        return token
    }

    @discardableResult
    func saveSmartFilter(
        name: String, query: String, id: UUID = UUID(), now: Date = Date()
    ) throws -> SmartFilter {
        guard vault.isReady else {
            let reason: ClipboardVaultRecoveryReason
            if case let .readOnlyRecovery(value) = vault.state { reason = value }
            else { reason = .keychainUnavailable }
            throw ClipboardVaultError.notReady(reason)
        }
        var candidate = smartFilters
        let filter = candidate.save(name: name, query: query, id: id, now: now)
        let data = try candidate.encoded()
        try io.sync { try writeProtectedData(data, to: smartFiltersURL) }
        smartFilters = candidate
        return filter
    }

    func deleteSmartFilter(_ id: UUID) throws {
        guard vault.isReady else {
            let reason: ClipboardVaultRecoveryReason
            if case let .readOnlyRecovery(value) = vault.state { reason = value }
            else { reason = .keychainUnavailable }
            throw ClipboardVaultError.notReady(reason)
        }
        var candidate = smartFilters
        candidate.remove(id)
        let data = try candidate.encoded()
        try io.sync { try writeProtectedData(data, to: smartFiltersURL) }
        smartFilters = candidate
    }

    // MARK: - Mutate

    func togglePin(_ id: UUID) {
        guard vault.isReady else { return }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        record.pinned.toggle()
        // A new pin joins the band at the end, where it is visibly an arrival rather than
        // something that pushed the existing order around; taking the pin off drops the
        // rank with it, so a row that is not in the band never carries a place in it.
        record.pinnedRank = record.pinned ? highestPinnedRank + 1 : nil
        records.remove(at: index)
        insertSorted(record)
        scheduleFlush()
    }

    /// Moves one pinned row to another place in the 收藏 band, both indices counted within
    /// the band rather than within the whole history.
    ///
    /// Called on every row the pointer crosses during a drag, not once when it is
    /// released: the list rearranging under the pointer is what tells the user where the
    /// row will land. So it renumbers the whole band each time — a pass over a handful of
    /// entries — rather than trying to patch two ranks and leave gaps behind.
    func movePinned(from source: Int, to destination: Int) {
        guard vault.isReady else { return }
        var band = records.filter(\.pinned)
        guard band.indices.contains(source), band.indices.contains(destination),
              source != destination
        else { return }

        band.insert(band.remove(at: source), at: destination)
        var ranks: [UUID: Int] = [:]
        for (rank, record) in band.enumerated() { ranks[record.id] = rank }
        for index in records.indices {
            guard let rank = ranks[records[index].id] else { continue }
            records[index].pinnedRank = rank
        }
        sortRecords()
        scheduleFlush()
    }

    /// Replaces a text entry's body in place, keeping its id, its position and its
    /// pinned state — an edit is a correction to something already in the history, not a
    /// new capture, and a row that jumped to the top on every typo fix would be useless.
    ///
    /// Everything derived from the payload has to move with it. The digest above all: it
    /// is what collapses a re-copy onto an existing row, so leaving the old one behind
    /// would mean copying the *pre-edit* text again quietly restores it here.
    ///
    /// The payload is written synchronously rather than on `io`, because the caller's
    /// next move is usually to paste this entry and the paste path reads the payload back
    /// off disk. A few kilobytes of typed text on a deliberate, once-per-edit action is
    /// not the place to be clever about blocking.
    @discardableResult
    func updateText(id: UUID, newText: String) -> ClipRecord? {
        guard vault.isReady else { return nil }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }

        // One key covers it: `NSPasteboard.PasteboardType.string` *is*
        // "public.utf8-plain-text", which is the type every reader here looks for first.
        let payload: ClipPayload = [["public.utf8-plain-text": Data(newText.utf8)]]
        guard let payloadData = ClipPayloadCoder.encode(payload) else {
            log.error("edited payload could not be serialised for \(id.uuidString, privacy: .public)")
            return nil
        }
        // Only ever `.text` or `.url` — a link edited into prose should stop filtering as
        // a link, and prose edited into a link should start.
        let kind = ClipCapture.textKind(for: newText)
        var record = records[index]
        record.kind = kind
        record.contentTag = ClipCapture.contentTag(for: String(newText.prefix(Self.tagSourceLimit)))
        record.preview = ClipCapture.makePreview(kind: kind, payload: payload)
        record.digest = ClipPayloadCoder.digest(payload)
        record.byteSize = ClipPayloadCoder.byteSize(payload)
        record.oversized = false
        guard let pendingData = encodeJournal(
            PendingRecord(epoch: indexEpoch &+ 1, record: record)
        ) else { return nil }

        // `insert` may still have its original payload queued. Joining the same serial
        // writer here first lets that old write finish and then atomically replaces it
        // with the edit. Returning only after this block also preserves the paste path's
        // guarantee that an edit is readable immediately.
        // Cancel the old metadata snapshot *before* joining the writer, so it cannot be
        // committed between the old payload and this replacement while the main thread
        // is waiting for the queue.
        flushToken?.cancel()
        flushToken = nil
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let editedPayloadURL = payloadURL(id)
        let editedPendingURL = pendingURL(id)
        let payloadWritten = io.sync { [log] in
            do {
                try writeProtectedData(payloadData, to: editedPayloadURL)
                try writeProtectedData(pendingData, to: editedPendingURL)
                failedPayloadIDs.remove(id)
                return true
            } catch {
                failedPayloadIDs.insert(id)
                log.error("edited payload write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard payloadWritten else { return nil }
        let previousDigest = records[index].digest
        records[index] = record
        digestLock.lock()
        payloadDigests[id] = record.digest
        digestLock.unlock()
        if digestToID[previousDigest] == id { digestToID[previousDigest] = nil }
        digestToID[record.digest] = id

        var searchData: Data?
        if let entry = ClipSearch.makeEntry(text: newText) {
            searchIndex[id] = entry
            searchData = Data(entry.text.utf8)
            invertedSearchIndex.upsert(record: record, entry: entry)
        } else {
            searchIndex[id] = nil
            invertedSearchIndex.remove(id)
        }
        scheduleSearchSegmentWrite(ClipSearchIndex.slot(for: id))

        let searchURL = searchTextURL(id)
        io.async { [weak self, log] in
            guard let self, self.vault.isReady else { return }
            do {
                if let searchData {
                    try self.writeProtectedData(searchData, to: searchURL)
                } else {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: searchURL.path) {
                        try fm.removeItem(at: searchURL)
                    }
                }
            } catch {
                log.error("edited search text write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        scheduleFlush()
        return record
    }

    /// Clears everything except pinned entries, which is what "clear history" means to
    /// someone who deliberately starred a few things.
    func clearUnpinned() {
        guard vault.isReady else { return }
        // A pending undo would otherwise be able to put rows back *after* the user asked
        // for the history to be cleared, which is the one thing "清空" must not do.
        commitPendingDeletion()
        let doomed = records.filter { !$0.pinned }.map(\.id)
        guard doomed.isEmpty || persistTombstones(doomed, epoch: indexEpoch &+ 1) else { return }
        records.removeAll { !$0.pinned }
        removeFiles(for: doomed)
        scheduleFlush(immediate: doomed.count > 1)
    }

    func clearAll() {
        guard vault.isReady else { return }
        commitPendingDeletion()
        let doomed = records.map(\.id)
        guard doomed.isEmpty || persistTombstones(doomed, epoch: indexEpoch &+ 1) else { return }
        records.removeAll()
        removeFiles(for: doomed)
        scheduleFlush(immediate: doomed.count > 1)
    }

    // MARK: - Undoable deletion

    /// One batch of rows taken out of the history but not yet off the disk.
    private struct PendingDeletion {
        var records: [ClipRecord]
        /// Their full-text bodies, lifted out of `searchIndex` so a deleted row cannot
        /// keep matching searches, and kept here so an undo need not read them back.
        var entries: [UUID: ClipSearchEntry]
    }

    private var pendingDeletion: PendingDeletion?
    private var pendingDeletionWork: DispatchWorkItem?

    /// The rows that are out of the history but still recoverable — see `deleteUndoable`.
    ///
    /// Exposed because "not in `records`" is not the same thing as "nothing owns this
    /// file" for as long as a batch is waiting for ⌘Z, and `reconcileOrphans` is the one
    /// place that difference is destructive.
    var pendingDeletionIDs: Set<UUID> {
        Set(pendingDeletion?.records.map(\.id) ?? [])
    }

    /// How long a deletion stays undoable. Long enough to read the HUD and reach for
    /// ⌘Z, short enough that the files are not left lying around.
    private static let undoWindow: TimeInterval = 10

    /// Deletes rows: gone from the history immediately, but recoverable for a few
    /// seconds. The only way anything is deleted one row at a time — retention and
    /// "clear history" are wholesale and are not undoable, which is what those two mean.
    ///
    /// Only the index entry is really removed — the payload, the thumbnail and the
    /// search sidecar stay on disk until the batch is committed, because rebuilding a
    /// payload from nothing is not something an undo can do. Exactly one batch is held:
    /// a second deletion makes the first one permanent, which keeps the amount of
    /// deleted-but-present data bounded by one user action rather than by how long the
    /// panel has been open.
    ///
    /// Quitting inside the window simply leaves the files behind; the next launch's
    /// `reconcileOrphans` collects them, because the index no longer names them.
    ///
    /// Returns the records that were actually removed, in history order — ids naming
    /// nothing are skipped rather than counted.
    @discardableResult
    func deleteUndoable(_ ids: [UUID]) -> [ClipRecord] {
        guard vault.isReady else { return [] }
        guard !ids.isEmpty else { return [] }

        let doomed = Set(ids)
        let removed = records.filter { doomed.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        guard persistTombstones(
            removed.map(\.id), epoch: indexEpoch &+ 1
        ) else { return [] }

        var entries: [UUID: ClipSearchEntry] = [:]
        var searchSlots = Set<Int>()
        records.removeAll { record in
            guard doomed.contains(record.id) else { return false }
            // The files stay for the undo window, but the row is out of the history, so
            // a re-copy of the same bytes must record a new entry rather than bump this
            // one — exactly what the old linear scan over `records` did.
            if digestToID[record.digest] == record.id { digestToID[record.digest] = nil }
            if let entry = searchIndex[record.id] {
                entries[record.id] = entry
                searchIndex[record.id] = nil
            }
            searchSlots.insert(ClipSearchIndex.slot(for: record.id))
            return true
        }
        // `removed` is the same predicate `removeAll` just applied, so this is exactly
        // the set the per-id loop used to walk — handed over at once so each affected
        // segment repacks its gram table once instead of once per row.
        invertedSearchIndex.remove(Set(removed.map(\.id)))
        scheduleSearchSegmentWrites(searchSlots)
        commitPendingDeletion()
        pendingDeletion = PendingDeletion(records: removed, entries: entries)
        let work = DispatchWorkItem { [weak self] in self?.commitPendingDeletion() }
        pendingDeletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: work)

        scheduleFlush(immediate: removed.count > 1)
        log.info("\(removed.count) entries deleted; undoable for \(Int(Self.undoWindow))s")
        return removed
    }

    /// Durable proof that these ids must not be rebuilt from their surviving payloads.
    ///
    /// A single deletion keeps its own file, named after the id — that is what the panel
    /// does, it is one encrypted write, and the recovery path has always found it there.
    /// A wholesale clear does not: `clearAll` on a full history used to hand this method
    /// five thousand ids and get five thousand seal/write/fsync round trips, on the main
    /// thread, before a single row left the list. All of them together are now one file.
    ///
    /// Residual risk, and its mitigation. A build older than the batch format cannot
    /// decode `batch-*.json`: its journal reader logs and moves on. So if this process
    /// died after the batch was written but before the index that no longer names those
    /// rows was committed, *and* the user then downgraded, that older build would rebuild
    /// the deleted rows from their surviving payloads. Every caller of the batch path
    /// therefore flushes with `immediate: true`, which drops the 0.6s debounce and puts
    /// the commit on the file queue right behind this write — the window is the time to
    /// seal and fsync one index, not the time a user spends idle. It cannot be closed
    /// entirely without making the deletion synchronous on the main thread, which is the
    /// freeze this change exists to remove.
    private func persistTombstones(_ ids: [UUID], epoch: UInt64) -> Bool {
        guard !ids.isEmpty else { return true }
        let url: URL
        let data: Data?
        if ids.count == 1 {
            url = tombstoneURL(ids[0])
            data = encodeJournal(Tombstone(epoch: epoch, id: ids[0]))
        } else {
            url = tombstoneDirectory.appendingPathComponent(
                "\(Self.tombstoneBatchPrefix)\(epoch)-\(UUID().uuidString).json"
            )
            data = encodeJournal(TombstoneBatch(epoch: epoch, ids: ids))
        }
        guard let data else { return false }
        return io.sync { [log] in
            do {
                try writeProtectedData(data, to: url)
                return true
            } catch {
                log.error("clipboard tombstone write failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Puts the last undoable batch back, and returns what it restored. Empty when the
    /// window has passed, when nothing was deleted, or when the batch was already made
    /// permanent by a later deletion.
    @discardableResult
    func undoLastDelete() -> [ClipRecord] {
        guard vault.isReady else { return [] }
        pendingDeletionWork?.cancel()
        pendingDeletionWork = nil
        guard let pending = pendingDeletion else { return [] }
        pendingDeletion = nil

        // A row deleted and then copied again came back under a new id while it was in
        // the buffer. Restoring the old one would leave two rows for one thing, and the
        // digest is what collapses a re-copy onto an existing row — so the survivor is
        // the one already in the history, and the buffered copy is finally let go.
        let present = Set(records.map(\.digest))
        var restored: [ClipRecord] = []
        var superseded: [UUID] = []
        for record in pending.records {
            guard !present.contains(record.digest) else {
                superseded.append(record.id)
                continue
            }
            restored.append(record)
        }

        guard !restored.isEmpty else {
            if !superseded.isEmpty { removeFiles(for: superseded) }
            return []
        }

        records.append(contentsOf: restored)
        sortRecords()
        digestLock.lock()
        for record in restored { payloadDigests[record.id] = record.digest }
        digestLock.unlock()
        for record in restored { digestToID[record.digest] = record.id }
        // The band has to be renumbered, not just re-sorted. A restored pin carries the
        // rank it held when it was deleted, while `togglePin` hands out
        // `highestPinnedRank + 1` computed from `records` alone — so a row pinned during
        // the undo window was given a number the buffered row is still holding. Two pins
        // with one rank fall through to `createdAt` in `sortRecords`, which rearranges a
        // band the user arranged by hand and then writes that order down on the next
        // flush. Rewriting 0..n over the whole band is idempotent, so it costs nothing to
        // do it unconditionally.
        normalizePinnedRanks(reclaimedBy: Set(restored.map(\.id)))
        for record in restored {
            if let entry = pending.entries[record.id] {
                searchIndex[record.id] = entry
                invertedSearchIndex.upsert(record: record, entry: entry)
            }
        }
        scheduleSearchSegmentWrites(Set(restored.map { ClipSearchIndex.slot(for: $0.id) }))
        if !superseded.isEmpty { removeFiles(for: superseded) }
        scheduleFlush()
        log.info("restored \(restored.count) deleted entries")
        return restored
    }

    /// Makes the pending batch permanent now. Called when the window expires, when a
    /// second batch arrives, and by anything that must not be undone into.
    func commitPendingDeletion() {
        guard vault.isReady else { return }
        pendingDeletionWork?.cancel()
        pendingDeletionWork = nil
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        removeFiles(for: pending.records.map(\.id))
    }

    /// The one place every deletion path funnels through, so neither the in-memory
    /// search text nor a cached thumbnail can outlive the record it belongs to.
    private func removeFiles(for ids: [UUID]) {
        guard vault.isReady else { return }
        digestLock.lock()
        let removedDigests: [(id: UUID, digest: String)] = ids.compactMap { id in
            payloadDigests[id].map { (id: id, digest: $0) }
        }
        for id in ids { payloadDigests[id] = nil }
        digestLock.unlock()
        // Only where the digest still names *this* id. A launch-window capture discarded
        // in favour of the identical row already on disk, and a deletion superseded by a
        // re-copy, both arrive here holding a digest that a live record owns.
        for (id, digest) in removedDigests where digestToID[digest] == id {
            digestToID[digest] = nil
        }
        var searchSlots = Set<Int>()
        for id in ids {
            searchIndex[id] = nil
            searchSlots.insert(ClipSearchIndex.slot(for: id))
        }
        invertedSearchIndex.remove(Set(ids))
        scheduleSearchSegmentWrites(searchSlots)
        let payloads = ids.map(payloadURL)
        let thumbs = ids.map(thumbnailURL)
        let searchTexts = ids.map(searchTextURL)
        let pending = ids.map(pendingURL)
        io.async { [weak self, log] in
            let fm = FileManager.default
            for id in ids { self?.failedPayloadIDs.remove(id) }
            for url in payloads + thumbs + searchTexts + pending {
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.removeItem(at: url)
                } catch {
                    log.error("clipboard file removal failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Retention

    /// Rolling eviction rather than a periodic wipe: age *and* count, whichever bites
    /// first, and pinned entries are exempt from both. A scheduled "delete everything"
    /// would take the things the user deliberately kept along with the noise.
    func sweep() {
        guard vault.isReady else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)

        // A read-only pass first. `sweep` runs on every single capture and almost always
        // has nothing to do; deciding that used to cost a full copy of the history, a
        // `removeAll` walk over the copy, and — once over the cap — one `remove(at:)`
        // per evicted row, each of them shifting the whole tail of the array.
        var expired = 0
        var unpinned = 0
        for record in records where !record.pinned {
            unpinned += 1
            if record.createdAt < cutoff { expired += 1 }
        }
        let over = max(0, (unpinned - expired) - maxItems)
        guard expired > 0 || over > 0 else { return }

        var doomed: [UUID] = []
        doomed.reserveCapacity(expired + over)
        var doomedIDs = Set<UUID>()
        for record in records where !record.pinned && record.createdAt < cutoff {
            doomed.append(record.id)
            doomedIDs.insert(record.id)
        }
        if over > 0 {
            var remaining = over
            // Oldest first, so walk from the back of the sorted history.
            for record in records.reversed() where remaining > 0 {
                guard !record.pinned, !doomedIDs.contains(record.id) else { continue }
                doomed.append(record.id)
                doomedIDs.insert(record.id)
                remaining -= 1
            }
        }

        guard !doomed.isEmpty else { return }
        guard persistTombstones(doomed, epoch: indexEpoch &+ 1) else { return }
        records.removeAll { doomedIDs.contains($0.id) }
        removeFiles(for: doomed)
        log.info("clipboard sweep evicted \(doomed.count) entries")
        scheduleFlush(immediate: doomed.count > 1)
        // Last, so the store is fully consistent before anyone reacts to it.
        onEvicted?(doomed)
    }

    /// Deletes files with no matching record after a healthy load. If this launch had to
    /// recover its index, the same files are quarantined instead: an untrusted index can
    /// never be used as proof that content is safe to destroy.
    func reconcileOrphans() {
        guard vault.isReady else { return }
        // A pending deletion's files count as live. `deleteUndoable` takes the rows out of
        // `records` on purpose while leaving their payload, thumbnail and search text on
        // disk for the length of the undo window — and 设置 › 清理孤儿文件 puts this method
        // under the user's finger, so it can be run inside that window. Judged by
        // `records` alone, the batch waiting for ⌘Z is precisely what this would delete,
        // and the undo would then restore rows with nothing behind them: no payload to
        // paste, no thumbnail to draw, no body to search.
        var live = Set(records.map(\.id.uuidString))
        live.formUnion(pendingDeletionIDs.map(\.uuidString))
        let dirs = [dataDirectory, thumbDirectory, searchDirectory]
        // Deleting needs positive proof that a completed walk found no payload bytes
        // this build's writer could not have produced. Without one an unknown file is
        // indistinguishable from an injected one, and the launch fast path only ever
        // read `index.json`. Every caller runs from `whenLoaded` or later, by which
        // point the deferred walk has finished, so a healthy library still reclaims its
        // orphans — including one that happens to contain a symbolic link, which is
        // handled file by file below rather than by switching reclamation off.
        let shouldQuarantine = quarantineOrphans || !isLayoutVerifiedFreeOfForeignPayloads
        // Quarantine with nowhere to put anything is not quarantine, it is a silent
        // leak: every orphan stays exactly where it is, one log line each, and 设置 ›
        // 清理孤儿文件 reports success while the directory grows without bound. A layout
        // rejected after launch has no incident directory of its own, so open one.
        if shouldQuarantine, recoveryIncidentDirectory == nil {
            recoveryIncidentDirectory = makeRecoveryIncidentDirectory()
        }
        let incident = shouldQuarantine ? recoveryIncidentDirectory : nil
        io.async { [weak self, log] in
            let fm = FileManager.default
            for dir in dirs {
                let names: [String]
                do {
                    names = try fm.contentsOfDirectory(atPath: dir.path)
                } catch {
                    log.error("cannot enumerate clipboard directory \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
                for name in names {
                    let stem = (name as NSString).deletingPathExtension
                    guard !live.contains(stem) else { continue }
                    let url = dir.appendingPathComponent(name)
                    // Never follow, and never unlink, a symbolic link. It is not a
                    // payload this store wrote, `removeItem` would erase the only
                    // evidence that something put it here, and moving it would carry
                    // that evidence somewhere the user is not looking. Leaving it is
                    // also why a link no longer blocks the reclamation of everything
                    // around it: the two decisions are independent.
                    var info = stat()
                    if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                        log.error("clipboard orphan sweep left a symbolic link untouched: \(url.path, privacy: .public)")
                        continue
                    }
                    if shouldQuarantine {
                        guard let self, let incident else {
                            log.error("orphan retained because the recovery quarantine is unavailable: \(url.path, privacy: .public)")
                            continue
                        }
                        self.quarantine(url, in: incident, category: dir.lastPathComponent)
                    } else {
                        do {
                            try fm.removeItem(at: url)
                        } catch {
                            log.error("orphan removal failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    /// What the settings screen shows: the shape of the history, and where its bytes are.
    ///
    /// The counts come from `records`, which the caller already has to be on the main
    /// thread to read; the three directory sizes are the part worth a background pass.
    /// Split by directory rather than reported as one number because the three grow for
    /// very different reasons — a screenshot-heavy history is mostly `data/`, and a
    /// `thumbs/` or `search/` that has outgrown it means orphans to clean up.
    struct Statistics: Equatable {
        var counts: [ClipKind: Int] = [:]
        var total = 0
        var pinned = 0
        var payloadBytes: Int64 = 0
        var thumbnailBytes: Int64 = 0
        var searchBytes: Int64 = 0

        var diskBytes: Int64 { payloadBytes + thumbnailBytes + searchBytes }
    }

    /// Main-thread only, like every other read of `records`; `completion` comes back on
    /// the main thread too. Queued behind whatever `io` is already doing, so a refresh
    /// asked for right after `reconcileOrphans` measures what the cleanup left behind.
    func statistics(completion: @escaping (Statistics) -> Void) {
        var counted = Statistics()
        counted.total = records.count
        for record in records {
            counted.counts[record.kind, default: 0] += 1
            if record.pinned { counted.pinned += 1 }
        }

        let dataDir = dataDirectory
        let thumbDir = thumbDirectory
        let searchDir = searchDirectory
        let snapshot = counted
        io.async {
            var stats = snapshot
            stats.payloadBytes = ClipStore.byteSize(of: dataDir)
            stats.thumbnailBytes = ClipStore.byteSize(of: thumbDir)
            stats.searchBytes = ClipStore.byteSize(of: searchDir)
            DispatchQueue.main.async { completion(stats) }
        }
    }

    private static func byteSize(of directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        for name in names {
            let path = directory.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else { continue }
            total += size.int64Value
        }
        return total
    }
}

// MARK: - Image helpers

extension NSImage {
    /// The size in real pixels. `NSImage.size` is in points and lies about a Retina
    /// screenshot by a factor of two.
    var representationPixelSize: (width: Int, height: Int) {
        var width = 0
        var height = 0
        for rep in representations {
            width = max(width, rep.pixelsWide)
            height = max(height, rep.pixelsHigh)
        }
        if width == 0 || height == 0 {
            return (Int(size.width.rounded()), Int(size.height.rounded()))
        }
        return (width, height)
    }

    func downscaledPNG(maxDimension: CGFloat) -> Data? {
        let pixels = representationPixelSize
        guard pixels.width > 0, pixels.height > 0 else { return nil }

        let scale = min(1, maxDimension / CGFloat(max(pixels.width, pixels.height)))
        let target = NSSize(
            width: max(1, (CGFloat(pixels.width) * scale).rounded()),
            height: max(1, (CGFloat(pixels.height) * scale).rounded())
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target),
             from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
