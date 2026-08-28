import Foundation
import HyperKeyBrokerSupport
import Security
import XCTest

@testable import Hyper

final class ClipboardVaultTests: XCTestCase {
    private final class Provider: ClipboardVaultKeyProviding {
        let service = "tests.vault"
        let account = UUID().uuidString
        var stored: Data?
        var trustState: Data?
        var loadError: Error?
        private(set) var createCount = 0

        init(stored: Data? = nil) { self.stored = stored }

        func loadKey() throws -> Data? {
            if let loadError { throw loadError }
            return stored
        }

        func createKey() throws -> Data {
            createCount += 1
            let key = Data((0..<32).map(UInt8.init))
            stored = key
            return key
        }

        func loadTrustState() throws -> Data? { trustState }
        func storeTrustState(_ data: Data) throws { trustState = data }
    }

    func testBrokerClonesLegacyKeyByteForByteAndMaintainsTrustSlot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-keychain-migration-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("migration.keychain-db").path
        let password = Data("temporary-test-password".utf8)
        var keychain: SecKeychain?
        let created = password.withUnsafeBytes { bytes in
            SecKeychainCreate(
                path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain
            )
        }
        XCTAssertEqual(created, errSecSuccess)
        let isolatedKeychain = try XCTUnwrap(keychain)
        defer { SecKeychainDelete(isolatedKeychain) }

        let historical = Data((0..<32).map { UInt8(255 - $0) })
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: HyperKeyBrokerAccounts.service,
            kSecAttrAccount as String: HyperKeyBrokerAccounts.legacyKeys[0],
            kSecValueData as String: historical,
            kSecUseKeychain as String: isolatedKeychain,
        ]
        XCTAssertEqual(SecItemAdd(legacyQuery as CFDictionary, nil), errSecSuccess)

        let provider = HyperKeyBrokerStore(targetKeychain: isolatedKeychain)
        XCTAssertEqual(try provider.loadKey(), historical)
        XCTAssertEqual(try provider.loadKey(), historical)

        func copiedItem(account: String) throws -> SecKeychainItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: HyperKeyBrokerAccounts.service,
                kSecAttrAccount as String: account,
                kSecMatchSearchList as String: [isolatedKeychain],
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            XCTAssertEqual(
                SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess
            )
            return result as! SecKeychainItem
        }

        let current = try copiedItem(account: HyperKeyBrokerAccounts.key)
        var currentAccess: SecAccess?
        XCTAssertEqual(SecKeychainItemCopyAccess(current, &currentAccess), errSecSuccess)
        let access = try XCTUnwrap(currentAccess)
        // A custom temporary keychain does not synthesize the login keychain's
        // partition_id ACL. The release packaging check separately pins the executable
        // CDHash that securityd uses for that creator partition in production.
        let decrypt = try XCTUnwrap(
            SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt)
        )
        XCTAssertEqual(CFArrayGetCount(decrypt), 1)

        let firstTrust = Data("first-trust-state".utf8)
        let updatedTrust = Data("updated-trust-state".utf8)
        try provider.storeTrustState(firstTrust)
        XCTAssertEqual(try provider.loadTrustState(), firstTrust)
        try provider.storeTrustState(updatedTrust)
        XCTAssertEqual(try provider.loadTrustState(), updatedTrust)

        // The old recovery slot survives untouched; migration is additive and therefore
        // cannot strand a v1 library if the process exits between clone and adoption.
        let legacy = try copiedItem(account: HyperKeyBrokerAccounts.legacyKeys[0])
        var length: UInt32 = 0
        var content: UnsafeMutableRawPointer?
        XCTAssertEqual(
            SecKeychainItemCopyContent(legacy, nil, nil, &length, &content), errSecSuccess
        )
        defer { SecKeychainItemFreeContent(nil, content) }
        XCTAssertEqual(Data(bytes: content!, count: Int(length)), historical)
    }

    func testAESGCMRoundTripDoesNotExposePlaintextAndDetectsTampering() throws {
        let provider = Provider()
        let vault = ClipboardVault(provider: provider)
        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: false, hasLegacyPlaintext: false), .ready
        )

        let plaintext = Data("a highly recognisable clipboard secret".utf8)
        let sealed = try vault.seal(plaintext)
        XCTAssertFalse(sealed.range(of: plaintext) != nil)
        XCTAssertTrue(ClipboardVault.isSealed(sealed))
        XCTAssertEqual(try vault.open(sealed), plaintext)

        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try vault.open(tampered)) { error in
            XCTAssertEqual(error as? ClipboardVaultError, .authenticationFailed)
        }
        XCTAssertEqual(vault.state, .ready, "one corrupt file is not proof that the key is bad")
        vault.markAuthenticationFailed()
        XCTAssertEqual(vault.state, .readOnlyRecovery(.authenticationFailed))
    }

    func testV2EnvelopeAuthenticatesStableStorageContext() throws {
        let provider = Provider()
        let vault = ClipboardVault(provider: provider)
        XCTAssertEqual(vault.prepare(library: .empty), .ready)
        let plaintext = Data("bound clipboard body".utf8)
        let source = ClipboardVault.storageContext(
            relativePath: "data/00000000-0000-0000-0000-000000000001.plist"
        )
        let destination = ClipboardVault.storageContext(
            relativePath: "data/00000000-0000-0000-0000-000000000002.plist"
        )
        let envelope = try vault.seal(plaintext, context: source)

        XCTAssertEqual(try vault.open(envelope, context: source), plaintext)
        XCTAssertThrowsError(try vault.open(envelope, context: destination)) { error in
            XCTAssertEqual(error as? ClipboardVaultError, .contextMismatch)
        }
    }

    func testMissingHistoricalKeyEntersReadOnlyWithoutCreatingReplacement() {
        let provider = Provider()
        let vault = ClipboardVault(provider: provider)

        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: true, hasLegacyPlaintext: false),
            .readOnlyRecovery(.missingKey)
        )
        XCTAssertEqual(provider.createCount, 0)
        XCTAssertThrowsError(try vault.seal(Data("must not write".utf8)))
    }

    func testInvalidHistoricalKeyIsExportableAndNeverOverwritten() throws {
        let invalid = Data("historical-but-corrupt-key".utf8)
        let provider = Provider(stored: invalid)
        let vault = ClipboardVault(provider: provider)

        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: true, hasLegacyPlaintext: false),
            .readOnlyRecovery(.invalidKey)
        )
        XCTAssertEqual(provider.createCount, 0)
        let material = vault.recoveryMaterial()
        XCTAssertEqual(material.keyBase64, invalid.base64EncodedString())
        XCTAssertEqual(material.recoveryReason, .invalidKey)
        XCTAssertNoThrow(try material.encoded())
    }

    func testLegacyPlaintextCanProvisionItsFirstKey() {
        let provider = Provider()
        let vault = ClipboardVault(provider: provider)

        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: false, hasLegacyPlaintext: true), .ready
        )
        XCTAssertEqual(provider.createCount, 1)
    }

    func testKeychainFailureFailsClosed() {
        let provider = Provider()
        provider.loadError = ClipboardVaultError.keychain(errSecInteractionNotAllowed)
        let vault = ClipboardVault(provider: provider)

        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: true, hasLegacyPlaintext: false),
            .readOnlyRecovery(.keychainUnavailable)
        )
        XCTAssertEqual(provider.createCount, 0)
    }

    func testFiveThousandSmallTextReadWriteSearchOverheadStaysBelowTenPercent() throws {
        let texts = (0..<5_000).map { index in
            Data("clipboard benchmark row \(index) needle "
                .padding(toLength: 192, withPad: "x", startingAt: 0).utf8)
        }
        let benchmarkRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-vault-benchmark-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: benchmarkRoot) }
        let provider = Provider()
        let vault = ClipboardVault(provider: provider)
        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: false, hasLegacyPlaintext: false), .ready
        )

        // Alternate order to cancel APFS/metadata-cache warm-up bias, then compare the
        // two complete workloads: 5,000 atomic writes + 5,000 reads/authentications +
        // a full in-memory text search. This measures the user-facing storage path, not
        // an AES microbenchmark against a no-op.
        let plainA = try benchmark(
            texts, encrypted: false, vault: vault,
            root: benchmarkRoot.appendingPathComponent("plain-a")
        )
        let sealedA = try benchmark(
            texts, encrypted: true, vault: vault,
            root: benchmarkRoot.appendingPathComponent("sealed-a")
        )
        let sealedB = try benchmark(
            texts, encrypted: true, vault: vault,
            root: benchmarkRoot.appendingPathComponent("sealed-b")
        )
        let plainB = try benchmark(
            texts, encrypted: false, vault: vault,
            root: benchmarkRoot.appendingPathComponent("plain-b")
        )
        let plain = plainA + plainB
        let sealed = sealedA + sealedB
        let overhead = (sealed / plain) - 1
        print(String(format:
            "VAULT_BENCHMARK_5000 plain=%.6fs encrypted=%.6fs overhead=%.2f%%",
            plain, sealed, overhead * 100
        ))
        XCTAssertLessThanOrEqual(
            overhead, 0.10,
            String(format: "AES-GCM storage overhead %.2f%% exceeds 10%%", overhead * 100)
        )
    }

    private func benchmark(
        _ texts: [Data], encrypted: Bool, vault: ClipboardVault, root: URL
    ) throws -> TimeInterval {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let started = ProcessInfo.processInfo.systemUptime
        for (index, text) in texts.enumerated() {
            let bytes = encrypted ? try vault.seal(text) : text
            try bytes.write(
                to: root.appendingPathComponent("\(index).bin"), options: .atomic
            )
        }
        var matches = 0
        let needle = Data("needle".utf8)
        for index in texts.indices {
            let stored = try Data(contentsOf: root.appendingPathComponent("\(index).bin"))
            let plain = encrypted ? try vault.open(stored) : stored
            if plain.range(of: needle) != nil { matches += 1 }
        }
        XCTAssertEqual(matches, texts.count)
        return ProcessInfo.processInfo.systemUptime - started
    }
}
