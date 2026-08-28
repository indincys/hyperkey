import AppKit
import CryptoKit
import XCTest

@testable import Hyper

/// The store is main-thread-only state with background disk I/O behind it, so every test
/// here runs on the main thread and waits on the store's own seams — `whenLoaded` for the
/// asynchronous index read, `waitForPendingWrites` for the file queue, `flushNow` for the
/// debounced index write.
final class ClipStoreTests: XCTestCase {
    private final class MutableVaultProvider: ClipboardVaultKeyProviding {
        let service = "tests.clipstore.vault"
        let account = UUID().uuidString
        var key: Data?
        var trust: Data?
        private(set) var createCount = 0

        func loadKey() throws -> Data? { key }
        func createKey() throws -> Data {
            createCount += 1
            if let key { return key }
            let created = Data((0..<32).map(UInt8.init))
            key = created
            return created
        }
        func loadTrustState() throws -> Data? { trust }
        func storeTrustState(_ data: Data) throws { trust = data }
    }

    private var root: URL!
    private var vault: ClipboardVault!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-store-tests-\(UUID().uuidString)", isDirectory: true)
        vault = ClipboardVault(
            provider: EphemeralClipboardVaultKeyProvider(scope: UUID().uuidString)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDefaultDirectoryKeepsBuildProductsOutOfTheProductionVault() {
        let bundle = URL(fileURLWithPath: "/tmp/hyper/.build/HyperQA.app", isDirectory: true)
        let selected = ClipStore.defaultDirectory(
            bundleURL: bundle,
            processIdentifier: 4242,
            temporaryDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertNotEqual(selected, ClipStore.directory)
        XCTAssertEqual(
            selected.path,
            "/tmp/Hyper-Clipboard-Development-4242"
        )
    }

    func testDefaultDirectoryUsesTheProductionVaultForInstalledApplication() {
        XCTAssertEqual(
            ClipStore.defaultDirectory(
                bundleURL: URL(fileURLWithPath: "/Applications/Hyper.app", isDirectory: true),
                processIdentifier: 4242,
                temporaryDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            ),
            ClipStore.directory
        )
    }

    // MARK: - Helpers

    /// A store whose index has finished loading. Nothing may read `records` before this.
    private func makeStore(
        ioQueue: DispatchQueue? = nil,
        migrationFault: ClipStore.MigrationFaultInjection? = nil
    ) -> ClipStore {
        let store = ClipStore(
            root: root, vault: vault, ioQueue: ioQueue,
            migrationFault: migrationFault
        )
        let loaded = expectation(description: "index loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        return store
    }

    private func textInsertion(_ text: String, source: String? = "Tests") -> ClipStore.Insertion {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        return ClipStore.Insertion(
            payload: payload,
            kind: ClipCapture.textKind(for: text),
            oversized: false,
            byteSize: ClipPayloadCoder.byteSize(payload),
            sourceBundleID: nil,
            sourceName: source
        )
    }

    private func record(
        _ text: String, age: TimeInterval, pinned: Bool = false, id: UUID = UUID()
    ) -> ClipRecord {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        return ClipRecord(
            id: id,
            createdAt: Date().addingTimeInterval(-age),
            kind: .text,
            preview: text,
            digest: ClipPayloadCoder.digest(payload),
            byteSize: ClipPayloadCoder.byteSize(payload),
            sourceBundleID: nil,
            sourceName: "Tests",
            pinned: pinned
        )
    }

    /// Seeds `index.json` before the store is created, which is the only way to get
    /// records with a chosen age: `insert` always stamps them with now.
    private func seedIndex(_ records: [ClipRecord]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: root.appendingPathComponent("index.json"))
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private func decodeIndex() throws -> [ClipRecord] {
        let encrypted = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let data = try vault.open(
            encrypted, context: ClipboardVault.storageContext(relativePath: "index.json")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let legacy = try? decoder.decode([ClipRecord].self, from: data) { return legacy }
        struct Envelope: Decodable { var records: [ClipRecord] }
        return try decoder.decode(Envelope.self, from: data).records
    }

    private func writePayload(_ text: String, id: UUID) throws {
        let directory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        try XCTUnwrap(ClipPayloadCoder.encode(payload)).write(
            to: directory.appendingPathComponent("\(id.uuidString).plist"),
            options: .atomic
        )
    }

    private func writeEncryptedPayload(_ text: String, id: UUID) throws {
        let directory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        let plaintext = try XCTUnwrap(ClipPayloadCoder.encode(payload))
        let relative = "data/\(id.uuidString).plist"
        try vault.seal(
            plaintext, context: ClipboardVault.storageContext(relativePath: relative)
        ).write(to: directory.appendingPathComponent("\(id.uuidString).plist"), options: .atomic)
    }

    /// Exact envelope emitted by the pre-v2 release: the magic/version prefix is AAD,
    /// but role and path are not. Tests keep this independent from the production v1
    /// decoder so a shared implementation mistake cannot make migration self-confirming.
    private func sealLegacyV1(_ plaintext: Data, key: Data) throws -> Data {
        let header = Data([0x48, 0x59, 0x50, 0x45, 0x52, 0x56, 0x4c, 0x54, 0x01])
        let nonce = try AES.GCM.Nonce(
            data: Data(SHA256.hash(data: plaintext).prefix(12))
        )
        let box = try AES.GCM.seal(
            plaintext, using: SymmetricKey(data: key), nonce: nonce,
            authenticating: header
        )
        return header + (try XCTUnwrap(box.combined))
    }

    private func replaceWithLegacyV1(_ relative: String, key: Data) throws -> Data {
        let url = root.appendingPathComponent(relative)
        let plaintext = try Data(contentsOf: url)
        let envelope = try sealLegacyV1(plaintext, key: key)
        try envelope.write(to: url, options: .atomic)
        return envelope
    }

    private func recoveryFiles() throws -> [String] {
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recovery.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: recovery,
            includingPropertiesForKeys: nil
        )
        return (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent)
    }

    private func assertSealed0600(
        _ relativePath: String, excludes plaintext: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = root.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        XCTAssertTrue(ClipboardVault.isSealed(data), relativePath, file: file, line: line)
        if let plaintext {
            XCTAssertNil(data.range(of: Data(plaintext.utf8)), relativePath, file: file, line: line)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600, relativePath, file: file, line: line
        )
    }

    private func directoryMode(_ relativePath: String = "") throws -> Int? {
        let url = relativePath.isEmpty ? root! : root.appendingPathComponent(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - Insert

    func testInsertWritesTheRecordItsPayloadAndItsSearchText() throws {
        let store = makeStore()
        let inserted = store.insert(textInsertion("hello from the tests"))
        store.flushNow()
        store.waitForPendingWrites()

        XCTAssertEqual(store.records.map(\.id), [inserted.id])
        XCTAssertEqual(inserted.preview, "hello from the tests")
        XCTAssertEqual(inserted.sourceName, "Tests")

        XCTAssertTrue(exists("data/\(inserted.id.uuidString).plist"))
        XCTAssertTrue(exists("search/\(inserted.id.uuidString).txt"))
        XCTAssertFalse(exists("thumbs/\(inserted.id.uuidString).png"), "text has no thumbnail")

        let onDisk = try decodeIndex()
        XCTAssertEqual(onDisk.map(\.id), [inserted.id])

        let payload = try XCTUnwrap(store.payload(for: inserted.id))
        XCTAssertEqual(ClipCapture.plainText(from: payload), "hello from the tests")

        let searchEnvelope = try Data(
            contentsOf: root.appendingPathComponent("search/\(inserted.id.uuidString).txt")
        )
        let searchText = try XCTUnwrap(String(
            data: vault.open(
                searchEnvelope,
                context: ClipboardVault.storageContext(
                    relativePath: "search/\(inserted.id.uuidString).txt"
                )
            ),
            encoding: .utf8
        ))
        XCTAssertEqual(searchText, "hello from the tests")
    }

    func testOversizedEntryKeepsItsMetadataButWritesNoPayload() {
        let store = makeStore()
        var insertion = textInsertion("far too big")
        insertion.oversized = true
        let inserted = store.insert(insertion)
        store.waitForPendingWrites()

        XCTAssertTrue(store.records[0].oversized)
        XCTAssertFalse(exists("data/\(inserted.id.uuidString).plist"))
        // Still searchable: knowing what you copied is why the row is kept at all.
        XCTAssertTrue(exists("search/\(inserted.id.uuidString).txt"))
    }

    func testRecopyBumpsToTheTopInsteadOfDuplicating() {
        let store = makeStore()
        let first = store.insert(textInsertion("first"))
        let second = store.insert(textInsertion("second"))
        XCTAssertEqual(store.records.map(\.id), [second.id, first.id])

        let again = store.insert(textInsertion("first"))
        XCTAssertEqual(again.id, first.id, "the same content keeps its identity")
        XCTAssertEqual(store.records.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.records.count, 2)
    }

    func testRecopyPreservesPinnedStateAndSource() {
        let store = makeStore()
        let pinnedItem = store.insert(textInsertion("keep me", source: "Safari"))
        store.togglePin(pinnedItem.id)
        XCTAssertTrue(store.records[0].pinned)

        store.insert(textInsertion("something else"))
        let again = store.insert(textInsertion("keep me", source: "Ghostty"))

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(again.id, pinnedItem.id)
        XCTAssertTrue(again.pinned, "a re-copy must not silently unpin")
        XCTAssertEqual(again.sourceName, "Safari", "the original source survives the bump")
        XCTAssertEqual(store.records[0].id, pinnedItem.id, "pinned entries float to the top")
    }

    func testGenerationAdvancesOnEveryChange() {
        let store = makeStore()
        let before = store.generation
        store.insert(textInsertion("something"))
        XCTAssertGreaterThan(store.generation, before)
    }

    func testEveryPersistentClipboardArtifactIsAuthenticatedAndPrivate() throws {
        let store = makeStore()
        let secret = "recognisable vault secret 9f4b7e"
        let inserted = store.insert(textInsertion(secret))
        store.waitForPendingWrites()

        try assertSealed0600(
            "data/\(inserted.id.uuidString).plist", excludes: secret
        )
        try assertSealed0600(
            "search/\(inserted.id.uuidString).txt", excludes: secret
        )
        try assertSealed0600("pending/\(inserted.id.uuidString).json", excludes: secret)

        XCTAssertTrue(store.flushNow())
        try assertSealed0600("index.json", excludes: secret)
        try assertSealed0600("index.json.backup", excludes: secret)

        let deleted = store.insert(textInsertion("tombstone body"))
        store.waitForPendingWrites()
        XCTAssertEqual(store.deleteUndoable([deleted.id]).map(\.id), [deleted.id])
        try assertSealed0600("tombstones/\(deleted.id.uuidString).json")

        XCTAssertEqual(try directoryMode(), 0o700)
        for name in ["data", "thumbs", "search", "pending", "tombstones"] {
            XCTAssertEqual(try directoryMode(name), 0o700, name)
        }
    }

    func testThumbnailBytesAreEncryptedAndStillDecodeThroughStore() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let payload: ClipPayload = [[NSPasteboard.PasteboardType.png.rawValue: png]]
        let store = makeStore()
        let inserted = store.insert(ClipStore.Insertion(
            payload: payload,
            kind: .image,
            oversized: false,
            byteSize: ClipPayloadCoder.byteSize(payload),
            sourceBundleID: nil,
            sourceName: "Tests"
        ))
        store.waitForPendingWrites()

        XCTAssertTrue(inserted.hasThumbnail)
        try assertSealed0600("thumbs/\(inserted.id.uuidString).png")
        XCTAssertNotNil(store.thumbnail(for: inserted))
    }

    func testLegacyPlaintextLibraryMigratesThroughVerifiedShadowTree() throws {
        let legacy = record("legacy body worth protecting", age: 30)
        try seedIndex([legacy])
        try writePayload("legacy body worth protecting", id: legacy.id)
        let searchDirectory = root.appendingPathComponent("search", isDirectory: true)
        try FileManager.default.createDirectory(at: searchDirectory, withIntermediateDirectories: true)
        try Data("legacy body worth protecting".utf8).write(
            to: searchDirectory.appendingPathComponent("\(legacy.id.uuidString).txt")
        )
        let queueURL = root.appendingPathComponent("queue.json")
        let queue = PasteQueue(storeURL: queueURL)
        queue.restore()
        queue.enqueue(legacy.id)
        queue.flushNow()
        let legacyQueueBytes = try Data(contentsOf: queueURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.path
        )

        let store = makeStore()
        store.waitForPendingWrites()

        XCTAssertEqual(store.vaultState, .ready)
        XCTAssertEqual(store.records.map(\.id), [legacy.id])
        XCTAssertEqual(ClipCapture.plainText(from: try XCTUnwrap(store.payload(for: legacy.id))),
                       "legacy body worth protecting")
        try assertSealed0600("index.json", excludes: "legacy body worth protecting")
        try assertSealed0600("data/\(legacy.id.uuidString).plist",
                             excludes: "legacy body worth protecting")
        try assertSealed0600("search/\(legacy.id.uuidString).txt",
                             excludes: "legacy body worth protecting")
        XCTAssertEqual(try Data(contentsOf: queueURL), legacyQueueBytes)
        XCTAssertFalse(ClipboardVault.isSealed(try Data(contentsOf: queueURL)))
        let relaunchedQueue = PasteQueue(storeURL: queueURL)
        relaunchedQueue.restore()
        XCTAssertEqual(relaunchedQueue.ids, [legacy.id])
        XCTAssertEqual(try directoryMode(), 0o700)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: root.deletingLastPathComponent().path
        )
        XCTAssertFalse(siblings.contains { $0.contains("vault-shadow") || $0.contains("vault-rollback") })
    }

    func testLegacyV1EncryptedLibraryMigratesAtomicallyWithExistingMasterKey() throws {
        let provider = MutableVaultProvider()
        let historicalKey = Data((0..<32).map { UInt8(255 - $0) })
        provider.key = historicalKey
        vault = ClipboardVault(provider: provider)

        let legacy = record("v1 encrypted upgrade body", age: 30)
        try seedIndex([legacy])
        try writePayload("v1 encrypted upgrade body", id: legacy.id)
        let searchDirectory = root.appendingPathComponent("search", isDirectory: true)
        try FileManager.default.createDirectory(
            at: searchDirectory, withIntermediateDirectories: true
        )
        try Data("v1 encrypted upgrade body".utf8).write(
            to: searchDirectory.appendingPathComponent("\(legacy.id.uuidString).txt")
        )
        let queueURL = root.appendingPathComponent("queue.json")
        let oldQueue = try JSONEncoder().encode([legacy.id])
        try oldQueue.write(to: queueURL)

        // The affected production layout carries both generations in v1.
        try Data(contentsOf: root.appendingPathComponent("index.json")).write(
            to: root.appendingPathComponent("index.json.backup"), options: .atomic
        )

        let oldIndex = try replaceWithLegacyV1("index.json", key: historicalKey)
        _ = try replaceWithLegacyV1("index.json.backup", key: historicalKey)
        _ = try replaceWithLegacyV1(
            "data/\(legacy.id.uuidString).plist", key: historicalKey
        )
        _ = try replaceWithLegacyV1(
            "search/\(legacy.id.uuidString).txt", key: historicalKey
        )
        XCTAssertTrue(ClipboardVault.isLegacyV1Sealed(oldIndex))
        XCTAssertFalse(ClipboardVault.isSealed(oldIndex))
        XCTAssertNil(provider.trust)

        var upgraded: ClipStore? = makeStore()
        upgraded!.waitForPendingWrites()
        XCTAssertEqual(upgraded!.vaultState, .ready)
        XCTAssertEqual(upgraded!.records.map(\.id), [legacy.id])
        XCTAssertEqual(
            ClipCapture.plainText(from: try XCTUnwrap(upgraded!.payload(for: legacy.id))),
            "v1 encrypted upgrade body"
        )
        XCTAssertEqual(try Data(contentsOf: queueURL), oldQueue)
        XCTAssertTrue(ClipboardVault.isSealed(
            try Data(contentsOf: root.appendingPathComponent("index.json"))
        ))
        XCTAssertTrue(ClipboardVault.isSealed(
            try Data(contentsOf: root.appendingPathComponent("index.json.backup"))
        ))
        XCTAssertFalse(ClipboardVault.isLegacyV1Sealed(
            try Data(contentsOf: root.appendingPathComponent("index.json"))
        ))
        XCTAssertNotNil(provider.trust)
        XCTAssertEqual(provider.createCount, 0, "migration must reuse the historical key")

        _ = upgraded!.insert(textInsertion("capture resumes after v1 upgrade"))
        XCTAssertTrue(upgraded!.drainPendingWrites(timeout: 5))
        XCTAssertEqual(upgraded!.records.count, 2)
        upgraded = nil

        vault = ClipboardVault(provider: provider)
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.vaultState, .ready)
        XCTAssertEqual(relaunched.records.count, 2)
        XCTAssertEqual(try Data(contentsOf: queueURL), oldQueue)
    }

    func testLegacyV1AuthenticationFailureLeavesOriginalTreeByteIdentical() throws {
        let provider = MutableVaultProvider()
        let storedKey = Data((0..<32).map(UInt8.init))
        let wrongEnvelopeKey = Data((0..<32).map { UInt8(255 - $0) })
        provider.key = storedKey
        vault = ClipboardVault(provider: provider)

        let legacy = record("v1 bytes must survive failed migration", age: 30)
        try seedIndex([legacy])
        try writePayload("v1 bytes must survive failed migration", id: legacy.id)
        let indexBefore = try replaceWithLegacyV1("index.json", key: wrongEnvelopeKey)
        let payloadRelative = "data/\(legacy.id.uuidString).plist"
        let payloadBefore = try replaceWithLegacyV1(payloadRelative, key: wrongEnvelopeKey)

        let blocked = makeStore()
        XCTAssertEqual(blocked.vaultState, .readOnlyRecovery(.migrationFailed))
        XCTAssertTrue(blocked.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), indexBefore)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(payloadRelative)), payloadBefore
        )
        XCTAssertFalse(exists(".vault-keycheck"))
    }

    func testMigrationFailureLeavesLegacyTreeByteIdenticalAndReadOnly() throws {
        let legacy = record("do not alter this legacy library", age: 30)
        try seedIndex([legacy])
        let indexURL = root.appendingPathComponent("index.json")
        let original = try Data(contentsOf: indexURL)
        let external = root.deletingLastPathComponent().appendingPathComponent(
            "hyper-vault-unsafe-\(UUID().uuidString)"
        )
        try Data("outside".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("unsafe-link"), withDestinationURL: external
        )

        let store = makeStore()

        XCTAssertEqual(store.vaultState, .readOnlyRecovery(.migrationFailed))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: indexURL), original)
        XCTAssertFalse(ClipboardVault.isSealed(try Data(contentsOf: indexURL)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("unsafe-link").path))
    }

    func testMissingHistoricalKeyIsReadOnlyAndPreservesEveryEncryptedByte() throws {
        var first: ClipStore? = makeStore()
        let inserted = first!.insert(textInsertion("history whose key disappears"))
        XCTAssertTrue(first!.drainPendingWrites(timeout: 5))
        let indexBefore = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let payloadBefore = try Data(contentsOf: root.appendingPathComponent(
            "data/\(inserted.id.uuidString).plist"
        ))
        first = nil

        let missingVault = ClipboardVault(
            provider: EphemeralClipboardVaultKeyProvider(scope: UUID().uuidString)
        )
        let store = ClipStore(root: root, vault: missingVault)
        let loaded = expectation(description: "read-only load completes")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(store.vaultState, .readOnlyRecovery(.missingKey))
        XCTAssertTrue(store.records.isEmpty)
        _ = store.insert(textInsertion("must not overwrite history"))
        XCTAssertFalse(store.flushNow())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), indexBefore)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("data/\(inserted.id.uuidString).plist")),
            payloadBefore
        )
        let recovery = try JSONDecoder().decode(
            ClipboardVaultRecoveryMaterial.self, from: store.exportVaultRecoveryMaterial()
        )
        XCTAssertEqual(recovery.recoveryReason, .missingKey)
        XCTAssertNil(recovery.keyBase64)
    }

    func testWrongHistoricalKeyIsExplicitAuthenticationRecoveryNotAnEmptyLibrary() throws {
        let provider = MutableVaultProvider()
        vault = ClipboardVault(provider: provider)
        var first: ClipStore? = makeStore()
        _ = first!.insert(textInsertion("authenticated historical body"))
        XCTAssertTrue(first!.drainPendingWrites(timeout: 5))
        let before = try Data(contentsOf: root.appendingPathComponent("index.json"))
        first = nil

        provider.key = Data(repeating: 0xA5, count: 32)
        let wrongVault = ClipboardVault(provider: provider)
        let store = ClipStore(root: root, vault: wrongVault)
        let loaded = expectation(description: "wrong-key recovery load")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(store.vaultState, .readOnlyRecovery(.authenticationFailed))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), before)
        XCTAssertFalse(store.flushNow())
    }

    // MARK: - Loading

    func testRecordsAreNotVisibleUntilTheIndexLoads() throws {
        try seedIndex([record("older", age: 60), record("newer", age: 30)])

        let store = ClipStore(root: root, vault: vault)
        XCTAssertFalse(store.isLoaded, "the read is asynchronous by design")
        XCTAssertTrue(store.records.isEmpty)

        let loaded = expectation(description: "loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.records.map(\.preview), ["older", "newer"])

        // Already loaded, so a later waiter runs straight away.
        var ranImmediately = false
        store.whenLoaded { ranImmediately = true }
        XCTAssertTrue(ranImmediately)
    }

    func testSearchIndexIsBackfilledFromPayloadsInTheBackground() throws {
        // A record written before the sidecar files existed: payload on disk, no
        // search/<uuid>.txt. Its full text is only findable once the scan has run.
        let seeded = record("preview only", age: 10)
        try seedIndex([seeded])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("data"), withIntermediateDirectories: true
        )
        let payload: ClipPayload = [["public.utf8-plain-text": Data("preview only, plus a buried needle".utf8)]]
        try XCTUnwrap(ClipPayloadCoder.encode(payload)).write(
            to: root.appendingPathComponent("data/\(seeded.id.uuidString).plist")
        )

        let store = ClipStore(root: root, vault: vault)
        let indexed = expectation(description: "search index ready")
        store.onSearchIndexLoaded = { indexed.fulfill() }
        wait(for: [indexed], timeout: 5)

        XCTAssertEqual(store.search("needle", kind: nil, pinnedOnly: false).map(\.id), [seeded.id])
        store.waitForPendingWrites()
        XCTAssertTrue(
            exists("search/\(seeded.id.uuidString).txt"),
            "the backfilled text is written out so the next launch need not redo it"
        )
    }

    func testFlushingBeforeTheIndexLoadsLeavesTheHistoryOnDisk() throws {
        try seedIndex([record("older", age: 60), record("newer", age: 30)])

        // Quitting in the first moments after launch. `records` is still empty, and an
        // empty index.json would turn every payload on disk into an orphan for the next
        // start's `reconcileOrphans` to delete.
        let store = ClipStore(root: root, vault: vault)
        XCTAssertFalse(store.isLoaded)
        store.flushNow()
        store.waitForPendingWrites()

        XCTAssertEqual(try decodeIndex().map(\.preview), ["older", "newer"])
    }

    func testALaunchWindowRecopyKeepsTheDiskRecordsIdentity() throws {
        let onDisk = record("copied twice", age: 3600, pinned: true)
        let other = record("something else", age: 7200)
        try seedIndex([onDisk, other])

        // XCTest does not promise this method owns the main thread. Suspend the injected
        // load queue so a warm decoder cannot finish and dispatch `adoptLoadedIndex`
        // before this test has made the launch-window insertion it intends to exercise.
        let controlledLoadQueue = DispatchQueue(label: "hyper.tests.clipstore.controlled-load")
        let controlledIOQueue = DispatchQueue(label: "hyper.tests.clipstore.controlled-io")
        controlledLoadQueue.suspend()
        controlledIOQueue.suspend()
        let store = ClipStore(
            root: root, vault: vault,
            ioQueue: controlledIOQueue, loadQueue: controlledLoadQueue
        )
        XCTAssertFalse(store.isLoaded)
        // Copied again before the index arrived, so it is recorded under a fresh id:
        // there is nothing in memory yet for the digest to collapse onto.
        var insertion = textInsertion("copied twice")
        let analysis = ClipCapture.PayloadAnalysis(
            digest: ClipPayloadCoder.digest(insertion.payload),
            byteSize: ClipPayloadCoder.byteSize(insertion.payload),
            plainText: "copied twice"
        )
        insertion.prepared = ClipStore.prepareCapturedPayload(
            insertion.payload, kind: insertion.kind, analysis: analysis
        )
        let captured = store.insert(insertion)
        XCTAssertNotEqual(captured.id, onDisk.id)

        let loaded = expectation(description: "loaded")
        store.whenLoaded { loaded.fulfill() }
        // Let the index read finish while the capture journal write is still queued.
        // Occupying main until that read returns also prevents adoption from racing this
        // hand-off when XCTest happens to invoke the method on a background thread.
        let releaseQueues = {
            controlledLoadQueue.resume()
            controlledLoadQueue.sync {}
            controlledIOQueue.resume()
        }
        if Thread.isMainThread { releaseQueues() }
        else { DispatchQueue.main.sync(execute: releaseQueues) }
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(store.records.count, 2, "the duplicate does not become a second row")
        XCTAssertNil(store.record(id: captured.id), "the launch-window capture is discarded")
        let survivor = try XCTUnwrap(store.record(id: onDisk.id))
        XCTAssertTrue(survivor.pinned, "the pin on disk survives the merge")
        XCTAssertGreaterThan(survivor.createdAt, onDisk.createdAt, "a re-copy still bumps it")
        XCTAssertEqual(store.records.map(\.id), [onDisk.id, other.id])

        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().map(\.id), [onDisk.id, other.id])
        XCTAssertFalse(
            exists("data/\(captured.id.uuidString).plist"),
            "the discarded capture's sidecar files go with it"
        )
        XCTAssertFalse(exists("search/\(captured.id.uuidString).txt"))
        XCTAssertEqual(
            store.search("copied", kind: nil, pinnedOnly: false).map(\.id), [onDisk.id],
            "the indexed body moves to the id that kept the row"
        )
    }

    func testANewCaptureDuringTheLaunchWindowJoinsTheLoadedHistory() throws {
        let seeded = record("already here", age: 3600)
        try seedIndex([seeded])

        let store = ClipStore(root: root, vault: vault)
        let captured = store.insert(textInsertion("brand new"))

        let loaded = expectation(description: "loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(store.records.map(\.id), [captured.id, seeded.id], "newest first")
        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().map(\.id), [captured.id, seeded.id])
    }

    func testCorruptIndexIsMovedAsideAndPayloadsSurvive() throws {
        let payloadID = UUID()
        try writePayload("recover me without a backup", id: payloadID)
        let orphanPayload = root.appendingPathComponent("data/\(payloadID.uuidString).plist")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: root.appendingPathComponent("index.json"))

        let store = makeStore()
        XCTAssertEqual(store.records.map(\.id), [payloadID])

        XCTAssertTrue(
            try recoveryFiles().contains("index.json"),
            "the unreadable index is kept in a recovery incident rather than deleted"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphanPayload.path),
            "a decodable payload is rebuilt into the history and remains pastable"
        )
        XCTAssertEqual(
            ClipCapture.plainText(from: try XCTUnwrap(store.payload(for: payloadID))),
            "recover me without a backup"
        )
    }

    func testCorruptIndexRestoresBackupRebuildsPayloadsAndQuarantinesGarbage() throws {
        var original: ClipStore? = makeStore()
        let backedUp = try XCTUnwrap(original).insert(textInsertion("present in the backup"))
        XCTAssertTrue(try XCTUnwrap(original).drainPendingWrites(timeout: 5))
        original = nil

        // Simulate an edit payload reaching disk before its newer index snapshot. The
        // backup still describes the old text, so recovery must reconcile known ids too.
        try writeEncryptedPayload("edited after the backup snapshot", id: backedUp.id)
        let recoveredID = UUID()
        try writeEncryptedPayload("captured after the last index commit", id: recoveredID)
        let garbageID = UUID()
        let garbageURL = root.appendingPathComponent("data/\(garbageID.uuidString).plist")
        try vault.seal(
            Data("not a payload plist".utf8),
            context: ClipboardVault.storageContext(
                relativePath: "data/\(garbageID.uuidString).plist"
            )
        ).write(to: garbageURL, options: .atomic)
        try vault.seal(
            Data("{ truncated".utf8),
            context: ClipboardVault.storageContext(relativePath: "index.json")
        ).write(
            to: root.appendingPathComponent("index.json"), options: .atomic
        )

        let recovered = makeStore()
        XCTAssertEqual(
            Set(recovered.records.map(\.id)), [backedUp.id, recoveredID],
            "the backup supplies known metadata and a valid unindexed payload is rebuilt"
        )
        XCTAssertEqual(
            ClipCapture.plainText(from: try XCTUnwrap(recovered.payload(for: recoveredID))),
            "captured after the last index commit"
        )
        XCTAssertEqual(
            recovered.record(id: backedUp.id)?.preview,
            "edited after the backup snapshot",
            "backup metadata is repaired from a newer payload for the same id"
        )

        // This is the real launch sequence: recovery is immediately followed by orphan
        // reconciliation. Recoverable content must still be live, while bytes that could
        // not be decoded are isolated for inspection rather than silently destroyed.
        recovered.reconcileOrphans()
        XCTAssertTrue(recovered.drainPendingWrites(timeout: 5))
        XCTAssertTrue(exists("data/\(backedUp.id.uuidString).plist"))
        XCTAssertTrue(exists("data/\(recoveredID.uuidString).plist"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: garbageURL.path))

        let isolated = try recoveryFiles()
        XCTAssertTrue(isolated.contains("index.json"), "the damaged index is retained")
        XCTAssertTrue(
            isolated.contains("\(garbageID.uuidString).plist"),
            "an unreadable payload is quarantined instead of deleted"
        )
        XCTAssertEqual(Set(try decodeIndex().map(\.id)), [backedUp.id, recoveredID])
    }

    func testNewerBackupWinsOverDecodableStalePrimaryAndSparesItsPayload() throws {
        var store: ClipStore? = makeStore()
        let first = try XCTUnwrap(store).insert(textInsertion("in both snapshots"))
        XCTAssertTrue(try XCTUnwrap(store).drainPendingWrites(timeout: 5))
        let stalePrimary = try Data(contentsOf: root.appendingPathComponent("index.json"))

        let newer = try XCTUnwrap(store).insert(textInsertion("only in the newer backup"))
        XCTAssertTrue(try XCTUnwrap(store).drainPendingWrites(timeout: 5))
        store = nil
        try stalePrimary.write(to: root.appendingPathComponent("index.json"), options: .atomic)

        let recovered = makeStore()
        XCTAssertEqual(Set(recovered.records.map(\.id)), [first.id, newer.id])
        recovered.reconcileOrphans()
        XCTAssertTrue(recovered.drainPendingWrites(timeout: 5))
        XCTAssertTrue(exists("data/\(newer.id.uuidString).plist"))
        XCTAssertEqual(
            ClipCapture.plainText(from: try XCTUnwrap(recovered.payload(for: newer.id))),
            "only in the newer backup"
        )
    }

    func testRecoveryTombstonePreventsPendingDeletionFromBeingResurrected() throws {
        var store: ClipStore? = makeStore()
        let doomed = try XCTUnwrap(store).insert(textInsertion("deleted but payload still present"))
        XCTAssertTrue(try XCTUnwrap(store).drainPendingWrites(timeout: 5))
        XCTAssertEqual(try XCTUnwrap(store).deleteUndoable([doomed.id]).map(\.id), [doomed.id])
        try XCTUnwrap(store).flushNow()
        XCTAssertTrue(exists("data/\(doomed.id.uuidString).plist"), "undo still owns the payload")
        store = nil

        try Data("broken primary".utf8).write(
            to: root.appendingPathComponent("index.json"), options: .atomic
        )
        try Data("broken backup".utf8).write(
            to: root.appendingPathComponent("index.json.backup"), options: .atomic
        )

        let recovered = makeStore()
        XCTAssertNil(recovered.record(id: doomed.id))
        XCTAssertFalse(recovered.records.contains { $0.preview.contains("deleted but") })
    }

    func testRecoveryWithoutBackupSynchronouslySolidifiesBothIndexes() throws {
        let recoveredID = UUID()
        try writePayload("survive repeated recovery kills", id: recoveredID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("broken primary".utf8).write(
            to: root.appendingPathComponent("index.json"), options: .atomic
        )

        var firstLaunch: ClipStore? = makeStore()
        XCTAssertEqual(try XCTUnwrap(firstLaunch).records.map(\.id), [recoveredID])
        XCTAssertEqual(try decodeIndex().map(\.id), [recoveredID])
        XCTAssertTrue(exists("index.json.backup"))
        firstLaunch = nil

        let secondLaunch = makeStore()
        XCTAssertEqual(secondLaunch.records.map(\.id), [recoveredID])
        XCTAssertNotNil(secondLaunch.payload(for: recoveredID))
    }

    func testRestartAfterUniqueIndexWasQuarantinedBeforeReplacementRecoversPayload() throws {
        let recoveredID = UUID()
        try writePayload("survive quarantine to replacement kill window", id: recoveredID)

        // Exact disk state after the only damaged index was moved aside, but before the
        // first recovered index's atomic rename: no primary or backup, only payload bytes
        // and the recovery incident proving this is not a brand-new library.
        let incident = root.appendingPathComponent(
            "recovery/interrupted-recovery", isDirectory: true
        )
        try FileManager.default.createDirectory(at: incident, withIntermediateDirectories: true)
        try Data("the quarantined damaged index".utf8).write(
            to: incident.appendingPathComponent("index.json"), options: .atomic
        )
        XCTAssertFalse(exists("index.json"))
        XCTAssertFalse(exists("index.json.backup"))

        let restarted = makeStore()
        XCTAssertEqual(restarted.records.map(\.id), [recoveredID])
        XCTAssertEqual(try decodeIndex().map(\.id), [recoveredID])
        XCTAssertTrue(exists("index.json.backup"), "recovery is solidified before loaded")

        restarted.reconcileOrphans()
        XCTAssertTrue(restarted.drainPendingWrites(timeout: 5))
        XCTAssertNotNil(restarted.payload(for: recoveredID))
    }

    // MARK: - Delete and clear

    func testDeleteRemovesTheRecordAndEveryFileBehindIt() {
        let store = makeStore()
        let inserted = store.insert(textInsertion("delete me"))
        store.waitForPendingWrites()
        XCTAssertTrue(exists("data/\(inserted.id.uuidString).plist"))

        store.deleteUndoable([inserted.id])
        // Deletion is undoable for a few seconds, so the files only go once the batch is
        // committed — which is what this test is about the far side of.
        store.commitPendingDeletion()
        store.waitForPendingWrites()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(id: inserted.id))
        XCTAssertFalse(exists("data/\(inserted.id.uuidString).plist"))
        XCTAssertFalse(exists("search/\(inserted.id.uuidString).txt"))
        XCTAssertNil(store.payload(for: inserted.id))
    }

    // MARK: - Undoable deletion

    func testPanelDeleteKeepsTheFilesUntilTheBatchIsCommitted() throws {
        let store = makeStore()
        let doomed = store.insert(textInsertion("a needle to delete"))
        let kept = store.insert(textInsertion("stays put"))
        store.waitForPendingWrites()

        let removed = store.deleteUndoable([doomed.id])
        store.waitForPendingWrites()

        XCTAssertEqual(removed.map(\.id), [doomed.id])
        XCTAssertEqual(store.records.map(\.id), [kept.id], "the row is gone from the history")
        XCTAssertTrue(
            store.search("needle", kind: nil, pinnedOnly: false).isEmpty,
            "and stops matching searches while it waits"
        )
        XCTAssertTrue(
            exists("data/\(doomed.id.uuidString).plist"),
            "but its payload has to survive, or the undo would have nothing to restore"
        )

        // Written out immediately: the undo buffer is memory only, so a crash inside the
        // window must not leave the deleted row back in index.json.
        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().map(\.id), [kept.id])

        store.commitPendingDeletion()
        store.waitForPendingWrites()
        XCTAssertFalse(exists("data/\(doomed.id.uuidString).plist"))
        XCTAssertFalse(exists("search/\(doomed.id.uuidString).txt"))
    }

    func testUndoPutsADeletedBatchBackInItsPlace() throws {
        let store = makeStore()
        let pinnedItem = store.insert(textInsertion("pinned and deleted"))
        store.togglePin(pinnedItem.id)
        let plain = store.insert(textInsertion("a needle, plain"))
        let bystander = store.insert(textInsertion("never touched"))

        store.deleteUndoable([pinnedItem.id, plain.id])
        XCTAssertEqual(store.records.map(\.id), [bystander.id])

        let restored = store.undoLastDelete()
        XCTAssertEqual(Set(restored.map(\.id)), [pinnedItem.id, plain.id])
        XCTAssertEqual(
            store.records.map(\.id), [pinnedItem.id, bystander.id, plain.id],
            "the pin floats back to the top and the rest lands newest-first"
        )
        XCTAssertTrue(store.records[0].pinned, "the pinned flag comes back with the row")
        XCTAssertEqual(
            store.search("needle", kind: nil, pinnedOnly: false).map(\.id), [plain.id],
            "and the full-text entry is rebuilt, not just the index row"
        )

        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(try decodeIndex().count, 3)
        XCTAssertTrue(exists("data/\(plain.id.uuidString).plist"))

        XCTAssertTrue(store.undoLastDelete().isEmpty, "one batch, undone once")
    }

    /// A restored pin brings its old rank back with it, and `togglePin` hands out numbers
    /// counted over the rows that are *present* — so a pin made inside the undo window is
    /// given a place the buffer is still holding. Two pins with one rank would be ordered
    /// by the clock instead, which has nothing to do with the order the user arranged.
    func testUndoRenumbersTheBandRatherThanRestoringAClashingRank() throws {
        let store = makeStore()
        let first = store.insert(textInsertion("pinned first"))
        let second = store.insert(textInsertion("pinned second"))
        store.togglePin(first.id)
        store.togglePin(second.id)
        let plain = store.insert(textInsertion("never pinned"))
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, nil])

        store.deleteUndoable([first.id, second.id])

        // With the band empty the next pin is handed rank 0 — the number the deleted row
        // is still holding in the buffer.
        let newcomer = store.insert(textInsertion("pinned during the undo window"))
        store.togglePin(newcomer.id)
        XCTAssertEqual(store.record(id: newcomer.id)?.pinnedRank, 0)

        XCTAssertEqual(store.undoLastDelete().map(\.id), [first.id, second.id])

        XCTAssertEqual(
            store.records.filter(\.pinned).map(\.pinnedRank), [0, 1, 2],
            "the band is renumbered 0..n, so no two pins claim one place"
        )
        XCTAssertEqual(
            store.records.map(\.id), [first.id, second.id, newcomer.id, plain.id],
            "the restored pins keep their order and the newcomer stays at the end of the band"
        )

        store.flushNow()
        store.waitForPendingWrites()
        XCTAssertEqual(
            try decodeIndex().map(\.pinnedRank), [0, 1, 2, nil],
            "and the settled order is what is written down"
        )
    }

    func testASecondDeleteMakesTheFirstOnePermanent() {
        let store = makeStore()
        let first = store.insert(textInsertion("first to go"))
        let second = store.insert(textInsertion("second to go"))
        store.waitForPendingWrites()

        store.deleteUndoable([first.id])
        store.deleteUndoable([second.id])
        store.waitForPendingWrites()

        XCTAssertFalse(
            exists("data/\(first.id.uuidString).plist"),
            "only one batch is held, so the older one is committed on the way past"
        )
        XCTAssertTrue(exists("data/\(second.id.uuidString).plist"))

        XCTAssertEqual(store.undoLastDelete().map(\.id), [second.id])
        XCTAssertEqual(store.records.map(\.id), [second.id])
    }

    func testClearingTheHistoryCannotBeUndoneInto() {
        let store = makeStore()
        let doomed = store.insert(textInsertion("deleted first"))
        store.deleteUndoable([doomed.id])

        // "清空历史" has to mean it — a pending undo putting rows back afterwards would be
        // the one outcome nobody could have asked for.
        store.clearAll()
        store.waitForPendingWrites()

        XCTAssertTrue(store.undoLastDelete().isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(exists("data/\(doomed.id.uuidString).plist"))
    }

    func testDeletingSomethingAbsentIsHarmless() {
        let store = makeStore()
        store.insert(textInsertion("stay"))
        XCTAssertTrue(store.deleteUndoable([UUID()]).isEmpty)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(
            store.undoLastDelete().isEmpty,
            "and it leaves no empty batch behind for ⌘Z to find"
        )
    }

    func testClearUnpinnedKeepsWhatWasDeliberatelyKept() {
        let store = makeStore()
        let kept = store.insert(textInsertion("kept"))
        store.togglePin(kept.id)
        let dropped = store.insert(textInsertion("dropped"))
        store.waitForPendingWrites()

        store.clearUnpinned()
        store.waitForPendingWrites()

        XCTAssertEqual(store.records.map(\.id), [kept.id])
        XCTAssertTrue(exists("data/\(kept.id.uuidString).plist"))
        XCTAssertFalse(exists("data/\(dropped.id.uuidString).plist"))
    }

    func testClearAllTakesPinnedEntriesToo() {
        let store = makeStore()
        let pinnedItem = store.insert(textInsertion("pinned"))
        store.togglePin(pinnedItem.id)
        let other = store.insert(textInsertion("other"))
        store.waitForPendingWrites()

        store.clearAll()
        store.waitForPendingWrites()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(exists("data/\(pinnedItem.id.uuidString).plist"))
        XCTAssertFalse(exists("data/\(other.id.uuidString).plist"))
    }

    func testTogglePinMovesTheRowAndBackAgain() {
        let store = makeStore()
        let first = store.insert(textInsertion("first"))
        let second = store.insert(textInsertion("second"))
        XCTAssertEqual(store.records.map(\.id), [second.id, first.id])

        store.togglePin(first.id)
        XCTAssertEqual(store.records.map(\.id), [first.id, second.id])
        store.togglePin(first.id)
        XCTAssertEqual(store.records.map(\.id), [second.id, first.id])
    }

    /// The 收藏 band is ordered by the ranks `togglePin` hands out, not by the clock — so a
    /// newer pin joins at the *end* of the band rather than jumping to the front of it,
    /// and unpinning takes the place in the band away with the pin.
    func testPinningRanksTheBandInTheOrderRowsWerePinned() {
        let store = makeStore()
        let first = store.insert(textInsertion("first"))
        let second = store.insert(textInsertion("second"))
        let third = store.insert(textInsertion("third"))

        // Deliberately against the clock: the oldest row is pinned first.
        store.togglePin(first.id)
        store.togglePin(third.id)

        XCTAssertEqual(
            store.records.map(\.id), [first.id, third.id, second.id],
            "pins keep the order they were pinned in, newest history last"
        )
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, nil])

        store.togglePin(first.id)
        XCTAssertNil(
            store.record(id: first.id)?.pinnedRank, "unpinning gives up the place in the band"
        )
        XCTAssertEqual(store.records.map(\.id), [third.id, second.id, first.id])

        // Re-pinned, it is an arrival: behind the rank already handed out, not in front.
        store.togglePin(first.id)
        XCTAssertEqual(store.records.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(store.records.map(\.pinnedRank), [1, 2, nil])
    }

    /// An index written before ranks existed has pins and no order for them. They are
    /// given one on the way in — the order they were already being shown in — and it is
    /// written back to disk, so it is decided once rather than on every launch.
    func testOlderPinnedEntriesAreGivenRanksOnLoad() throws {
        let older = record("pinned, older", age: 5_000, pinned: true)
        let newer = record("pinned, newer", age: 100, pinned: true)
        let plain = record("not pinned", age: 50)
        try seedIndex([newer, older, plain])

        let store = makeStore()
        XCTAssertEqual(
            store.records.map(\.preview), ["pinned, newer", "pinned, older", "not pinned"],
            "the band is left exactly as it was being shown"
        )
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, nil])

        store.flushNow()
        XCTAssertEqual(
            try decodeIndex().map(\.pinnedRank), [0, 1, nil],
            "the ranks are written down rather than re-derived on every launch"
        )
    }

    func testMovePinnedRewritesTheBandAndLeavesTheRestAlone() {
        let store = makeStore()
        let plain = store.insert(textInsertion("not pinned"))
        let a = store.insert(textInsertion("a"))
        let b = store.insert(textInsertion("b"))
        let c = store.insert(textInsertion("c"))
        for id in [a.id, b.id, c.id] { store.togglePin(id) }
        XCTAssertEqual(store.records.map(\.id), [a.id, b.id, c.id, plain.id])

        // The last of the band dragged to the front of it.
        store.movePinned(from: 2, to: 0)
        XCTAssertEqual(store.records.map(\.id), [c.id, a.id, b.id, plain.id])
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, 2, nil])

        // And back into the middle.
        store.movePinned(from: 0, to: 1)
        XCTAssertEqual(store.records.map(\.id), [a.id, c.id, b.id, plain.id])
        XCTAssertEqual(store.records.map(\.pinnedRank), [0, 1, 2, nil])

        // Indices outside the band, or a move to where the row already is, do nothing —
        // the drag calls this on every row the pointer crosses, including its own.
        store.movePinned(from: 1, to: 1)
        store.movePinned(from: 0, to: 3)
        store.movePinned(from: -1, to: 0)
        XCTAssertEqual(store.records.map(\.id), [a.id, c.id, b.id, plain.id])
        XCTAssertNil(store.record(id: plain.id)?.pinnedRank, "an unpinned row is never ranked")
    }

    // MARK: - Retention

    func testSweepEvictsByAgeAndExemptsPinned() throws {
        let old = record("old", age: 40 * 86400)
        let oldPinned = record("old but pinned", age: 40 * 86400, pinned: true)
        let fresh = record("fresh", age: 60)
        try seedIndex([oldPinned, fresh, old])

        let store = makeStore()
        store.retentionDays = 30
        store.maxItems = 1000
        store.sweep()

        XCTAssertEqual(Set(store.records.map(\.preview)), ["old but pinned", "fresh"])
    }

    func testSweepEvictsTheOldestOverTheCountCap() throws {
        let pinnedOld = record("pinned", age: 500, pinned: true)
        let seeded = (0..<4).map { record("entry \($0)", age: TimeInterval(400 - $0 * 10)) }
        // Newest-first, pinned at the top, which is the order the store keeps on disk.
        try seedIndex([pinnedOld] + seeded.reversed())

        let store = makeStore()
        store.retentionDays = 3650
        store.maxItems = 2
        store.sweep()

        XCTAssertEqual(store.records.count, 3, "two unpinned survivors plus the exempt pin")
        XCTAssertEqual(
            store.records.map(\.preview), ["pinned", "entry 3", "entry 2"],
            "the oldest unpinned entries go first"
        )
    }

    func testSweepDoesNothingWhenNothingIsOverTheLimits() throws {
        try seedIndex([record("a", age: 10), record("b", age: 20)])
        let store = makeStore()
        store.retentionDays = 30
        store.maxItems = 1000
        let before = store.generation
        store.sweep()
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.generation, before, "a no-op sweep must not schedule a write")
    }

    func testSweepReportsWhatItEvicted() throws {
        let doomed = record("old", age: 40 * 86400)
        try seedIndex([record("fresh", age: 60), doomed])

        let store = makeStore()
        store.retentionDays = 30
        store.maxItems = 1000
        var evicted: [UUID] = []
        // Retention is the one deletion the store performs unprompted, so it is the one
        // the paste queue cannot learn about any other way.
        store.onEvicted = { evicted.append(contentsOf: $0) }
        store.sweep()

        XCTAssertEqual(evicted, [doomed.id])
        XCTAssertEqual(store.records.map(\.preview), ["fresh"])
    }

    func testReconcileOrphansRemovesFilesWithNoRecord() throws {
        let store = makeStore()
        let live = store.insert(textInsertion("live"))
        store.waitForPendingWrites()

        let orphan = UUID()
        for (dir, ext) in [("data", "plist"), ("thumbs", "png"), ("search", "txt")] {
            try Data("stray".utf8).write(
                to: root.appendingPathComponent("\(dir)/\(orphan.uuidString).\(ext)")
            )
        }

        store.reconcileOrphans()
        store.waitForPendingWrites()

        XCTAssertFalse(exists("data/\(orphan.uuidString).plist"))
        XCTAssertFalse(exists("thumbs/\(orphan.uuidString).png"))
        XCTAssertFalse(exists("search/\(orphan.uuidString).txt"))
        XCTAssertTrue(exists("data/\(live.id.uuidString).plist"), "live payloads are untouched")
        XCTAssertTrue(exists("search/\(live.id.uuidString).txt"))
    }

    /// 设置 › 清理孤儿文件 can be pressed inside the ten seconds a deletion stays undoable, and
    /// the batch's files are deliberately still on disk with no record naming them. Taken
    /// for garbage they would leave ⌘Z restoring an empty shell of a row.
    func testReconcileOrphansSparesAPendingDeletionsFiles() throws {
        let store = makeStore()
        let doomed = store.insert(textInsertion("a needle, deleted but undoable"))
        let live = store.insert(textInsertion("never touched"))
        store.waitForPendingWrites()

        store.deleteUndoable([doomed.id])
        XCTAssertEqual(store.pendingDeletionIDs, [doomed.id])

        store.reconcileOrphans()
        store.waitForPendingWrites()

        XCTAssertTrue(
            exists("data/\(doomed.id.uuidString).plist"),
            "the payload the undo will need is not an orphan while the batch is held"
        )
        XCTAssertTrue(exists("search/\(doomed.id.uuidString).txt"))
        XCTAssertTrue(exists("data/\(live.id.uuidString).plist"))

        // And the row that comes back is whole, not a shell.
        XCTAssertEqual(store.undoLastDelete().map(\.id), [doomed.id])
        XCTAssertNotNil(store.payload(for: doomed.id), "it is pastable again")
        XCTAssertEqual(
            store.search("needle", kind: nil, pinnedOnly: false).map(\.id), [doomed.id],
            "and findable again"
        )

        // Once the batch is committed the same files are ordinary orphans.
        store.deleteUndoable([doomed.id])
        store.commitPendingDeletion()
        XCTAssertTrue(store.pendingDeletionIDs.isEmpty)
        store.reconcileOrphans()
        store.waitForPendingWrites()
        XCTAssertFalse(exists("data/\(doomed.id.uuidString).plist"))
    }

    // MARK: - Editing

    func testUpdateTextRefreshesEverythingDerivedFromThePayload() throws {
        let store = makeStore()
        let original = store.insert(textInsertion("some ordinary prose"))
        store.waitForPendingWrites()
        XCTAssertEqual(original.kind, .text)

        let edited = try XCTUnwrap(store.updateText(id: original.id, newText: "https://example.com/edited"))
        store.waitForPendingWrites()

        XCTAssertEqual(edited.id, original.id, "an edit is a correction, not a new capture")
        XCTAssertEqual(edited.kind, .url, "prose edited into a link starts filtering as a link")
        XCTAssertEqual(edited.preview, "https://example.com/edited")
        XCTAssertNotEqual(edited.digest, original.digest)
        XCTAssertEqual(store.records.map(\.id), [original.id], "the row does not jump to the top")

        let payload = try XCTUnwrap(store.payload(for: original.id))
        XCTAssertEqual(ClipCapture.plainText(from: payload), "https://example.com/edited")

        XCTAssertEqual(store.search("edited", kind: nil, pinnedOnly: false).map(\.id), [original.id])
        XCTAssertTrue(store.search("ordinary", kind: nil, pinnedOnly: false).isEmpty)
    }

    func testEditedDigestStopsTheOldTextFromReviningTheRow() throws {
        let store = makeStore()
        let original = store.insert(textInsertion("before the edit"))
        store.updateText(id: original.id, newText: "after the edit")

        // Copying the pre-edit text again must record a new entry rather than quietly
        // collapsing onto — and restoring — the row that was corrected.
        let recopied = store.insert(textInsertion("before the edit"))
        XCTAssertNotEqual(recopied.id, original.id)
        XCTAssertEqual(store.records.count, 2)
    }

    func testUpdateTextClearsTheOversizedFlag() {
        let store = makeStore()
        var insertion = textInsertion("too big to keep")
        insertion.oversized = true
        let original = store.insert(insertion)

        let edited = store.updateText(id: original.id, newText: "small now")
        XCTAssertEqual(edited?.oversized, false, "an edited entry is pastable again by definition")
    }

    func testContentTagIsDerivedOnCaptureAndReReadOnEdit() throws {
        let store = makeStore()
        let json = store.insert(textInsertion(#"{"ok": true}"#))
        XCTAssertEqual(json.contentTag, .json)

        // The tag has to be cleared as well as set, or an edited row would keep
        // describing what it used to hold.
        let edited = try XCTUnwrap(store.updateText(id: json.id, newText: "就是一句普通的话"))
        XCTAssertNil(edited.contentTag)
    }

    func testUpdateTextOnAnUnknownIDDoesNothing() {
        let store = makeStore()
        XCTAssertNil(store.updateText(id: UUID(), newText: "nowhere"))
    }

    func testTenThousandInsertThenImmediateEditsNeverLoseTheEditedPayload() throws {
        var store: ClipStore? = makeStore()
        var survivors: [(UUID, String)] = []

        for iteration in 0..<10_000 {
            let inserted = store!.insert(textInsertion("captured-\(iteration)"))
            let edited = "edited-\(iteration)"
            XCTAssertNotNil(store!.updateText(id: inserted.id, newText: edited))
            survivors.append((inserted.id, edited))
            if survivors.count > store!.maxItems { survivors.removeFirst() }
        }

        XCTAssertTrue(store!.drainPendingWrites(timeout: 30))
        for (id, expected) in survivors {
            let payload = try XCTUnwrap(store!.payload(for: id), "missing payload for \(id)")
            XCTAssertEqual(ClipCapture.plainText(from: payload), expected)
        }
        store = nil

        let reopened = makeStore()
        if reopened.searchSnapshot().invertedIndex == nil {
            let indexed = expectation(description: "restarted search index ready")
            reopened.onSearchIndexLoaded = { indexed.fulfill() }
            wait(for: [indexed], timeout: 10)
        }
        XCTAssertEqual(
            reopened.search("edited-9999", kind: nil, pinnedOnly: false).map(\.id),
            [survivors.last!.0]
        )
        XCTAssertTrue(
            reopened.search("captured-9999", kind: nil, pinnedOnly: false).isEmpty,
            "the pre-edit search body must not return after restart"
        )

        let snapshot = reopened.searchSnapshot()
        let expectedBySlot = Dictionary(grouping: snapshot.records) {
            ClipSearchIndex.slot(for: $0.id)
        }
        for (slot, expected) in expectedBySlot {
            let relative = String(format: "search-index/segment-%02d.json", slot)
            let sealed = try Data(contentsOf: root.appendingPathComponent(relative))
            let plain = try vault.open(
                sealed, context: ClipboardVault.storageContext(relativePath: relative)
            )
            let segment = try ClipSearchIndex.decodeSegment(plain, expectedSlot: slot)
            XCTAssertEqual(segment.documentCount, expected.count)
            for record in expected {
                let entry = try XCTUnwrap(snapshot.index[record.id])
                XCTAssertTrue(segment.contains(
                    recordID: record.id, recordDigest: record.digest, entry: entry
                ))
            }
        }
    }

    func testBoundedDrainCommitsPayloadAndMatchingIndexSnapshot() throws {
        let store = makeStore()
        let inserted = store.insert(textInsertion("captured value"))
        let edited = try XCTUnwrap(store.updateText(id: inserted.id, newText: "final edited value"))

        XCTAssertTrue(store.drainPendingWrites(timeout: 5))
        let payload = try XCTUnwrap(store.payload(for: inserted.id))
        XCTAssertEqual(ClipCapture.plainText(from: payload), "final edited value")
        let persisted = try XCTUnwrap(decodeIndex().first { $0.id == inserted.id })
        XCTAssertEqual(persisted.digest, edited.digest)
        XCTAssertEqual(persisted.preview, edited.preview)
        XCTAssertTrue(exists("index.json.backup"), "every committed index has a recovery copy")
    }

    func testPayloadWriteFailureFailsDrainAndDoesNotCommitAShellRecord() throws {
        let store = makeStore()
        let good = store.insert(textInsertion("durable baseline"))
        XCTAssertTrue(store.drainPendingWrites(timeout: 5))

        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: dataDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path
            )
        }

        let failed = store.insert(textInsertion("must never become an empty shell"))
        XCTAssertFalse(store.drainPendingWrites(timeout: 5))
        XCTAssertEqual(try decodeIndex().map(\.id), [good.id])
        XCTAssertFalse(exists("data/\(failed.id.uuidString).plist"))
    }

    func testTimedOutDrainCannotLaterCommitItsCancelledSnapshot() throws {
        let queue = DispatchQueue(label: "ClipStoreTests.suspended-io")
        var resumed = false
        defer { if !resumed { queue.resume() } }

        let store = makeStore(ioQueue: queue)
        queue.suspend()
        let first = store.insert(textInsertion("snapshot that times out"))
        XCTAssertFalse(store.drainPendingWrites(timeout: 0.01))
        let second = store.insert(textInsertion("accepted after the timeout"))

        queue.resume()
        resumed = true
        store.waitForPendingWrites()
        XCTAssertTrue(
            try decodeIndex().isEmpty,
            "the cancelled drain must not wake later and replace the empty baseline with its stale snapshot"
        )

        XCTAssertTrue(store.drainPendingWrites(timeout: 5))
        XCTAssertEqual(Set(try decodeIndex().map(\.id)), [first.id, second.id])
    }

    // MARK: - Vault binding and rollback resistance

    func testPayloadCiphertextCannotBeSwappedBetweenRecordPaths() throws {
        let store = makeStore()
        let first = store.insert(textInsertion("first bound payload"))
        let second = store.insert(textInsertion("second bound payload"))
        XCTAssertTrue(store.drainPendingWrites(timeout: 5))

        let firstURL = store.payloadLocation(for: first.id)
        let secondBytes = try Data(contentsOf: store.payloadLocation(for: second.id))
        try secondBytes.write(to: firstURL, options: .atomic)

        XCTAssertNil(
            store.payload(for: first.id),
            "ciphertext authenticated for another UUID/path must never be displayed or pasted"
        )
    }

    func testOldPayloadCiphertextReplayAtSamePathIsRejectedByIndexDigest() throws {
        let store = makeStore()
        let inserted = store.insert(textInsertion("payload generation one"))
        XCTAssertTrue(store.drainPendingWrites(timeout: 5))
        let payloadURL = store.payloadLocation(for: inserted.id)
        let oldCiphertext = try Data(contentsOf: payloadURL)

        XCTAssertNotNil(store.updateText(id: inserted.id, newText: "payload generation two"))
        XCTAssertTrue(store.drainPendingWrites(timeout: 5))
        try oldCiphertext.write(to: payloadURL, options: .atomic)

        XCTAssertNil(
            store.payload(for: inserted.id),
            "same-path replay authenticates its AAD but must fail the trusted index digest"
        )
    }

    func testCommittedIndexCiphertextReplayFailsClosed() throws {
        var firstLaunch: ClipStore? = makeStore()
        _ = firstLaunch!.insert(textInsertion("committed generation one"))
        XCTAssertTrue(firstLaunch!.drainPendingWrites(timeout: 5))
        let oldPrimary = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let oldBackup = try Data(contentsOf: root.appendingPathComponent("index.json.backup"))

        _ = firstLaunch!.insert(textInsertion("committed generation two"))
        XCTAssertTrue(firstLaunch!.drainPendingWrites(timeout: 5))
        firstLaunch = nil
        try oldPrimary.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        try oldBackup.write(to: root.appendingPathComponent("index.json.backup"), options: .atomic)

        let reopened = makeStore()
        XCTAssertEqual(reopened.vaultState, .readOnlyRecovery(.rollbackDetected))
        XCTAssertTrue(reopened.records.isEmpty)
    }

    func testInitializedLibraryWithDeletedKeycheckAndFlippedMagicFailsClosed() throws {
        var firstLaunch: ClipStore? = makeStore()
        _ = firstLaunch!.insert(textInsertion("initialized history must not be rewrapped"))
        XCTAssertTrue(firstLaunch!.drainPendingWrites(timeout: 5))
        firstLaunch = nil

        try FileManager.default.removeItem(at: root.appendingPathComponent(".vault-keycheck"))
        let index = root.appendingPathComponent("index.json")
        var tampered = try Data(contentsOf: index)
        tampered[0] ^= 0x01
        try tampered.write(to: index, options: .atomic)
        let before = try Data(contentsOf: index)

        let reopened = makeStore()
        XCTAssertEqual(reopened.vaultState, .readOnlyRecovery(.protectedLayoutInvalid))
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testDeletedTrustedInitializationMarkerCannotTurnTamperedHistoryIntoLegacy() throws {
        let provider = MutableVaultProvider()
        vault = ClipboardVault(provider: provider)
        var firstLaunch: ClipStore? = makeStore()
        _ = firstLaunch!.insert(textInsertion("trusted marker deletion evidence"))
        XCTAssertTrue(firstLaunch!.drainPendingWrites(timeout: 5))
        firstLaunch = nil

        provider.trust = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent(".vault-keycheck"))
        let index = root.appendingPathComponent("index.json")
        var tampered = try Data(contentsOf: index)
        tampered[0] ^= 0x01
        try tampered.write(to: index, options: .atomic)
        let before = try Data(contentsOf: index)

        vault = ClipboardVault(provider: provider)
        let reopened = makeStore()
        XCTAssertEqual(reopened.vaultState, .readOnlyRecovery(.trustStateMissing))
        XCTAssertEqual(provider.createCount, 1, "a replacement key must not be provisioned")
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testMissingKeyPlusMagicTamperNeverCreatesAReplacementKey() throws {
        let provider = MutableVaultProvider()
        vault = ClipboardVault(provider: provider)
        var firstLaunch: ClipStore? = makeStore()
        _ = firstLaunch!.insert(textInsertion("missing key tamper evidence"))
        XCTAssertTrue(firstLaunch!.drainPendingWrites(timeout: 5))
        firstLaunch = nil

        provider.key = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent(".vault-keycheck"))
        let index = root.appendingPathComponent("index.json")
        var tampered = try Data(contentsOf: index)
        tampered[0] ^= 0x01
        try tampered.write(to: index, options: .atomic)
        let before = try Data(contentsOf: index)

        vault = ClipboardVault(provider: provider)
        let reopened = makeStore()
        XCTAssertEqual(reopened.vaultState, .readOnlyRecovery(.missingKey))
        XCTAssertEqual(provider.createCount, 1)
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testAfterSwapCrashKeepsEncryptedLiveAndNextLaunchCleansPlaintextShadow() throws {
        let legacy = record("after swap crash legacy", age: 1)
        try seedIndex([legacy])
        try writePayload("after swap crash legacy", id: legacy.id)

        var interrupted: ClipStore? = makeStore(
            migrationFault: .init(crashAfterSwap: true)
        )
        XCTAssertEqual(interrupted!.vaultState, .readOnlyRecovery(.cleanupIncomplete))
        XCTAssertTrue(ClipboardVault.isSealed(
            try Data(contentsOf: root.appendingPathComponent("index.json"))
        ))
        interrupted = nil

        let resumed = makeStore()
        XCTAssertEqual(resumed.vaultState, .ready)
        XCTAssertEqual(resumed.records.map(\.id), [legacy.id])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: root.deletingLastPathComponent().path
        ).contains { $0.hasPrefix(".\(root.lastPathComponent).vault-shadow-") })
    }

    func testPartialPlaintextCleanupNeverRollsBackEncryptedLive() throws {
        let first = record("partial cleanup first", age: 2)
        let second = record("partial cleanup second", age: 1)
        try seedIndex([first, second])
        try writePayload("partial cleanup first", id: first.id)
        try writePayload("partial cleanup second", id: second.id)

        var interrupted: ClipStore? = makeStore(
            migrationFault: .init(failDuringCleanupAfterRemovingOneEntry: true)
        )
        XCTAssertEqual(interrupted!.vaultState, .readOnlyRecovery(.cleanupIncomplete))
        let encryptedTruth = try Data(contentsOf: root.appendingPathComponent("index.json"))
        XCTAssertTrue(ClipboardVault.isSealed(encryptedTruth))
        interrupted = nil

        let resumed = makeStore()
        XCTAssertEqual(resumed.vaultState, .ready)
        XCTAssertEqual(Set(resumed.records.map(\.id)), [first.id, second.id])
        XCTAssertTrue(ClipboardVault.isSealed(
            try Data(contentsOf: root.appendingPathComponent("index.json"))
        ))
    }

    // MARK: - Search through the store

    func testSearchFiltersByTermKindAndPin() {
        let store = makeStore()
        let text = store.insert(textInsertion("a needle in the text"))
        let link = store.insert(textInsertion("https://example.com/needle"))
        store.togglePin(link.id)

        XCTAssertEqual(
            Set(store.search("needle", kind: nil, pinnedOnly: false).map(\.id)), [text.id, link.id]
        )
        XCTAssertEqual(store.search("needle", kind: .url, pinnedOnly: false).map(\.id), [link.id])
        XCTAssertEqual(store.search("needle", kind: nil, pinnedOnly: true).map(\.id), [link.id])
        XCTAssertTrue(store.search("haystack", kind: nil, pinnedOnly: false).isEmpty)
    }

    func testSearchSnapshotCarriesBothHalves() {
        let store = makeStore()
        let inserted = store.insert(textInsertion("indexed body"))
        let snapshot = store.searchSnapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [inserted.id])
        XCTAssertEqual(snapshot.index[inserted.id]?.text, "indexed body")
    }

    func testSearchAsyncCancelsRunningVerifierAndLatestQueryCompletesPromptly() {
        let store = makeStore()
        let expensiveBody = String(repeating: "abcdefghij ", count: 2_900)
        for index in 0..<200 {
            _ = store.insert(textInsertion("\(index) \(expensiveBody)"))
        }
        let target = store.insert(textInsertion("fresh exact target"))

        let workerStarted = DispatchSemaphore(value: 0)
        var supersededCompleted = false
        let superseded = store.searchAsync(
            "zzzzzzzz", onStarted: { workerStarted.signal() }
        ) { _ in supersededCompleted = true }
        XCTAssertEqual(workerStarted.wait(timeout: .now() + 2), .success)
        // The first verifier now has enough time to enter a 32KiB lexical body. This is
        // deliberately not a pre-cancel/token-only test.
        usleep(20_000)

        let latestDone = expectation(description: "latest async query completed")
        let began = ProcessInfo.processInfo.systemUptime
        _ = store.searchAsync(#""fresh exact target""#) { result in
            guard case let .success(outcome) = result else {
                return XCTFail("latest query unexpectedly failed")
            }
            XCTAssertEqual(outcome.records.map(\.id), [target.id])
            latestDone.fulfill()
        }
        wait(for: [latestDone], timeout: 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
        XCTAssertTrue(superseded?.isCancelled == true)
        XCTAssertFalse(supersededCompleted)
    }
}
