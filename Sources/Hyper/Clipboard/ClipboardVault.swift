import CryptoKit
import Darwin
import Foundation
import HyperKeyBrokerSupport
import Security

enum ClipboardVaultRecoveryReason: String, Codable, Equatable {
    case missingKey, invalidKey, keychainUnavailable, migrationFailed, authenticationFailed
    case rollbackDetected, protectedLayoutInvalid, trustStateMissing, cleanupIncomplete
}

enum ClipboardVaultAccessState: Equatable {
    case ready
    case readOnlyRecovery(ClipboardVaultRecoveryReason)
}

struct ClipboardVaultRecoveryMaterial: Codable, Equatable {
    var formatVersion: Int
    var cipher: String
    var keyService: String
    var keyAccount: String
    var keyBase64: String?
    var keySHA256: String?
    var recoveryReason: ClipboardVaultRecoveryReason?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

protocol ClipboardVaultKeyProviding: AnyObject {
    var service: String { get }
    var account: String { get }
    func loadKey() throws -> Data?
    func createKey() throws -> Data
    func loadTrustState() throws -> Data?
    func storeTrustState(_ data: Data) throws
}

enum ClipboardVaultError: Error, Equatable {
    case notReady(ClipboardVaultRecoveryReason)
    case invalidEnvelope
    case unsupportedVersion(UInt8)
    case contextMismatch
    case authenticationFailed
    case keychain(OSStatus)
    case keyGenerationFailed(OSStatus)
    case invalidTrustState
    case indexCommitMismatch
}

enum ClipboardVaultLibraryDisposition {
    case empty, legacyPlaintext, encryptedV1, encryptedV2, invalidOrMixed
}

struct ClipboardVaultIndexExpectation: Equatable {
    var committedEpoch: UInt64?
    var committedHash: String?
    var pendingEpoch: UInt64?
    var pendingHash: String?
}

/// AES-256-GCM plus the small trusted state needed to distinguish a first migration
/// from tampering and a current index from a same-path replay.
final class ClipboardVault: @unchecked Sendable {
    static let formatVersion = 2
    static let keyService = "com.indincys.hyper.clipboard.vault"
    static let keyAccount = "master-key-v2"
    static let trustAccount = "trust-state-v2"
    static let legacyKeyAccount = "master-key-v1"
    static let legacyTrustAccount = "trust-state-v1"

    private static let magic = Data([0x48, 0x59, 0x50, 0x45, 0x52, 0x56, 0x4C, 0x54])
    private static let keyBytes = 32

    private struct TrustState: Codable, Equatable {
        enum Phase: String, Codable { case initializingNew, initializingLegacy, initialized }
        var version = 1
        var phase: Phase
        var committedIndexEpoch: UInt64? = nil
        var committedIndexHash: String? = nil
        var pendingIndexEpoch: UInt64? = nil
        var pendingIndexHash: String? = nil
    }

    private let provider: ClipboardVaultKeyProviding
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var rawKey: Data?
    private var trust: TrustState?
    private var accessState: ClipboardVaultAccessState = .readOnlyRecovery(.keychainUnavailable)

    init(provider: ClipboardVaultKeyProviding = KeyBrokerClipboardVaultKeyProvider()) {
        self.provider = provider
    }

    var state: ClipboardVaultAccessState { lock.withLock { accessState } }
    var isReady: Bool { state == .ready }
    /// Only cleanup recovery may expose authenticated history read-only. Missing trust,
    /// layout tampering, rollback and key failures preserve every historical byte and do
    /// not run loaders that could quarantine or rewrite evidence.
    var canDecrypt: Bool {
        lock.withLock {
            guard key != nil else { return false }
            if accessState == .ready { return true }
            return accessState == .readOnlyRecovery(.cleanupIncomplete)
        }
    }
    var isLegacyInitialization: Bool {
        lock.withLock { trust?.phase == .initializingLegacy }
    }

    @discardableResult
    func prepare(library: ClipboardVaultLibraryDisposition) -> ClipboardVaultAccessState {
        do {
            let decodedTrust: TrustState?
            if let data = try provider.loadTrustState() {
                guard let decoded = try? JSONDecoder().decode(TrustState.self, from: data),
                      decoded.version == 1 else {
                    setRecovery(.protectedLayoutInvalid)
                    return state
                }
                decodedTrust = decoded
            } else {
                decodedTrust = nil
            }
            lock.withLock { trust = decodedTrust }

            let loaded = try provider.loadKey()
            if let loaded {
                lock.withLock { rawKey = loaded }
                guard loaded.count == Self.keyBytes else {
                    setRecovery(.invalidKey)
                    return state
                }
                lock.withLock { key = SymmetricKey(data: loaded) }
            }

            if let decodedTrust {
                guard loaded != nil else {
                    setRecovery(.missingKey)
                    return state
                }
                switch decodedTrust.phase {
                case .initialized:
                    guard library == .encryptedV2 else {
                        setRecovery(.protectedLayoutInvalid); return state
                    }
                case .initializingLegacy:
                    guard library == .legacyPlaintext || library == .encryptedV1
                            || library == .encryptedV2 else {
                        setRecovery(.protectedLayoutInvalid); return state
                    }
                case .initializingNew:
                    guard library == .empty || library == .encryptedV2 else {
                        setRecovery(.protectedLayoutInvalid); return state
                    }
                }
                setReady()
                return state
            }

            switch library {
            case .encryptedV2, .invalidOrMixed:
                setRecovery(loaded == nil ? .missingKey : .trustStateMissing)
                return state
            case .encryptedV1:
                // v1 already proves possession of the historical master key through
                // AES-GCM authentication. Unlike an arbitrary plaintext tree plus a
                // stale key, it is therefore safe to enter the shadow migration state.
                guard loaded != nil else {
                    setRecovery(.missingKey)
                    return state
                }
                try persistTrust(TrustState(phase: .initializingLegacy))
            case .legacyPlaintext:
                guard loaded == nil else {
                    setRecovery(.trustStateMissing)
                    return state
                }
                try provisionKeyIfNeeded()
                try persistTrust(TrustState(phase: .initializingLegacy))
            case .empty:
                try provisionKeyIfNeeded()
                try persistTrust(TrustState(phase: .initializingNew))
            }
            setReady()
            return state
        } catch {
            setRecovery(.keychainUnavailable)
            return state
        }
    }

    @discardableResult
    func prepare(hasEncryptedLibrary: Bool, hasLegacyPlaintext: Bool) -> ClipboardVaultAccessState {
        let disposition: ClipboardVaultLibraryDisposition
        if hasEncryptedLibrary && hasLegacyPlaintext { disposition = .invalidOrMixed }
        else if hasEncryptedLibrary { disposition = .encryptedV2 }
        else if hasLegacyPlaintext { disposition = .legacyPlaintext }
        else { disposition = .empty }
        return prepare(library: disposition)
    }

    func finalizeInitialization() throws {
        guard isReady, var current = lock.withLock({ trust }) else {
            throw ClipboardVaultError.notReady(recoveryReason())
        }
        current.phase = .initialized
        try persistTrust(current)
    }

    /// v2 authenticates the complete header, including its canonical role/path/UUID.
    func seal(_ plaintext: Data, context: String = "test/default") throws -> Data {
        let key = try encryptionKey()
        let contextData = Data(context.utf8)
        guard !contextData.isEmpty, contextData.count <= Int(UInt16.max) else {
            throw ClipboardVaultError.invalidEnvelope
        }
        var length = UInt16(contextData.count).bigEndian
        var header = Self.magic + Data([UInt8(Self.formatVersion)])
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(contextData)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw ClipboardVaultError.invalidEnvelope }
        return header + combined
    }

    func open(_ envelope: Data, context expectedContext: String = "test/default") throws -> Data {
        let key = try decryptionKey()
        let fixed = Self.magic.count + 3
        guard envelope.count > fixed, envelope.prefix(Self.magic.count) == Self.magic else {
            throw ClipboardVaultError.invalidEnvelope
        }
        let version = envelope[Self.magic.count]
        guard version == UInt8(Self.formatVersion) else {
            throw ClipboardVaultError.unsupportedVersion(version)
        }
        let lengthStart = Self.magic.count + 1
        let length = envelope[lengthStart..<(lengthStart + 2)].reduce(0) {
            ($0 << 8) | Int($1)
        }
        let headerCount = fixed + length
        guard length > 0, envelope.count > headerCount,
              let embedded = String(data: envelope[fixed..<headerCount], encoding: .utf8)
        else { throw ClipboardVaultError.invalidEnvelope }
        guard embedded == expectedContext else { throw ClipboardVaultError.contextMismatch }
        let header = envelope.prefix(headerCount)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.dropFirst(headerCount))
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw ClipboardVaultError.authenticationFailed
        }
    }

    static func isSealed(_ data: Data) -> Bool {
        data.count >= magic.count + 3
            && data.prefix(magic.count) == magic
            && data[magic.count] == UInt8(formatVersion)
    }

    /// The pre-v2 envelope was `magic || 0x01 || AES.GCM.combined`, authenticating that
    /// nine-byte prefix but not the artifact role/path. It is accepted only by the
    /// one-way shadow migrator; every normal reader and writer remains v2-only with
    /// canonical role/path authentication.
    static func isLegacyV1Sealed(_ data: Data) -> Bool {
        let minimumCombinedBytes = 12 + 16 // nonce + authentication tag, empty body allowed
        return data.count >= magic.count + 1 + minimumCombinedBytes
            && data.prefix(magic.count) == magic
            && data[magic.count] == 1
    }

    func openLegacyV1(_ envelope: Data) throws -> Data {
        guard Self.isLegacyV1Sealed(envelope) else {
            throw ClipboardVaultError.invalidEnvelope
        }
        let key = try decryptionKey()
        do {
            let headerCount = Self.magic.count + 1
            let header = envelope.prefix(headerCount)
            let combined = envelope.dropFirst(headerCount)
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw ClipboardVaultError.authenticationFailed
        }
    }

    static func plaintextHash(_ data: Data) -> String {
        ClipHex.string(SHA256.hash(data: data))
    }

    /// One canonical derivation prevents a writer and reader from accidentally using
    /// different AAD. The relative path is included in full; role and UUID are repeated
    /// deliberately so cross-role and cross-record substitution are explicit failures.
    static func storageContext(relativePath: String, revision: String? = nil) -> String {
        let components = relativePath.split(separator: "/")
        let role: String
        switch relativePath {
        case "index.json": role = "index-primary"
        case "index.json.backup": role = "index-backup"
        case "index.transaction": role = "index-transaction"
        case ".vault-keycheck": role = "keycheck"
        default: role = components.first.map(String.init) ?? "unknown"
        }
        let id: String
        if components.count > 1 {
            id = URL(fileURLWithPath: String(components.last!))
                .deletingPathExtension().lastPathComponent.lowercased()
        } else {
            id = "-"
        }
        let base = "hyper-clipboard-v2|role=\(role)|path=\(relativePath)|id=\(id)"
        return revision.map { "\(base)|revision=\($0)" } ?? base
    }

    func indexExpectation() -> ClipboardVaultIndexExpectation {
        lock.withLock {
            ClipboardVaultIndexExpectation(
                committedEpoch: trust?.committedIndexEpoch,
                committedHash: trust?.committedIndexHash,
                pendingEpoch: trust?.pendingIndexEpoch,
                pendingHash: trust?.pendingIndexHash
            )
        }
    }

    func beginIndexCommit(epoch: UInt64, plaintext: Data) throws {
        guard isReady, var current = lock.withLock({ trust }), current.phase == .initialized else {
            throw ClipboardVaultError.notReady(recoveryReason())
        }
        current.pendingIndexEpoch = epoch
        current.pendingIndexHash = Self.plaintextHash(plaintext)
        try persistTrust(current)
    }

    func completeIndexCommit(epoch: UInt64, plaintext: Data) throws {
        guard isReady, var current = lock.withLock({ trust }) else {
            throw ClipboardVaultError.notReady(recoveryReason())
        }
        let hash = Self.plaintextHash(plaintext)
        guard current.pendingIndexEpoch == epoch, current.pendingIndexHash == hash else {
            throw ClipboardVaultError.indexCommitMismatch
        }
        current.committedIndexEpoch = epoch
        current.committedIndexHash = hash
        current.pendingIndexEpoch = nil
        current.pendingIndexHash = nil
        try persistTrust(current)
    }

    func markMigrationFailed() { setRecovery(.migrationFailed) }
    func markAuthenticationFailed() { setRecovery(.authenticationFailed) }
    func markRollbackDetected() { setRecovery(.rollbackDetected) }
    func markProtectedLayoutInvalid() { setRecovery(.protectedLayoutInvalid) }
    func markCleanupIncomplete() { setRecovery(.cleanupIncomplete) }

    func recoveryMaterial() -> ClipboardVaultRecoveryMaterial {
        let (raw, current) = lock.withLock { (rawKey, accessState) }
        let reason: ClipboardVaultRecoveryReason?
        if case let .readOnlyRecovery(value) = current { reason = value } else { reason = nil }
        return ClipboardVaultRecoveryMaterial(
            formatVersion: Self.formatVersion,
            cipher: "AES-256-GCM",
            keyService: provider.service,
            keyAccount: provider.account,
            keyBase64: raw?.base64EncodedString(),
            keySHA256: raw.map(Self.plaintextHash),
            recoveryReason: reason
        )
    }

    private func provisionKeyIfNeeded() throws {
        if lock.withLock({ key != nil }) { return }
        let created = try provider.createKey()
        guard created.count == Self.keyBytes else { throw ClipboardVaultError.invalidTrustState }
        lock.withLock {
            rawKey = created
            key = SymmetricKey(data: created)
        }
    }

    private func persistTrust(_ newValue: TrustState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try provider.storeTrustState(encoder.encode(newValue))
        lock.withLock { trust = newValue }
    }

    private func encryptionKey() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        guard accessState == .ready, let key else {
            throw ClipboardVaultError.notReady(recoveryReasonLocked())
        }
        return key
    }

    private func decryptionKey() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        guard let key else { throw ClipboardVaultError.notReady(recoveryReasonLocked()) }
        return key
    }

    private func recoveryReason() -> ClipboardVaultRecoveryReason {
        lock.withLock { recoveryReasonLocked() }
    }

    private func recoveryReasonLocked() -> ClipboardVaultRecoveryReason {
        if case let .readOnlyRecovery(value) = accessState { return value }
        return .keychainUnavailable
    }

    private func setReady() { lock.withLock { accessState = .ready } }
    private func setRecovery(_ reason: ClipboardVaultRecoveryReason) {
        lock.withLock { accessState = .readOnlyRecovery(reason) }
    }
}

private final class KeyBrokerClipboardVaultKeyProvider: ClipboardVaultKeyProviding {
    private static let installedApplicationPath = "/Applications/Hyper.app"
    private static let helperRelativePath = "Contents/Helpers/HyperKeyBroker"
    private static let helperRequirement =
        "identifier \"com.indincys.hyper.keybroker\" and "
        + "certificate leaf = H\"B9C36646F5DDD4CB7B116E5C3BAF7B3E747B377E\" and "
        + "cdhash H\"7CD11F860FA5379FF89ACD07723F0247B48A4038\""

    let service = HyperKeyBrokerAccounts.service
    let account = HyperKeyBrokerAccounts.key
    private let lock = NSLock()
    private var validatedHelperURL: URL?

    func loadKey() throws -> Data? { try request(.loadKey) }
    func createKey() throws -> Data {
        guard let value = try request(.createKey), value.count == 32 else {
            throw ClipboardVaultError.invalidTrustState
        }
        return value
    }
    func loadTrustState() throws -> Data? { try request(.loadTrustState) }
    func storeTrustState(_ data: Data) throws {
        _ = try request(.storeTrustState, value: data)
    }

    private func request(
        _ operation: HyperKeyBrokerOperation, value: Data? = nil
    ) throws -> Data? {
        try lock.withLock {
            let helper = try validatedHelperLocked()
            let encoded = try JSONEncoder().encode(HyperKeyBrokerRequest(
                operation: operation,
                valueBase64: value?.base64EncodedString()
            ))
            guard encoded.count <= 128 * 1024 else {
                throw ClipboardVaultError.invalidTrustState
            }

            let input = Pipe()
            let output = Pipe()
            let process = Process()
            process.executableURL = helper
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            do {
                try validateRunningHelper(process, expectedURL: helper)
            } catch {
                try? input.fileHandleForWriting.close()
                process.terminate()
                process.waitUntilExit()
                throw error
            }
            input.fileHandleForWriting.write(encoded)
            try input.fileHandleForWriting.close()
            let responseData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == EXIT_SUCCESS,
                  responseData.count <= 128 * 1024,
                  let response = try? JSONDecoder().decode(
                    HyperKeyBrokerResponse.self, from: responseData
                  ), response.error == nil else {
                throw ClipboardVaultError.keychain(errSecAuthFailed)
            }
            if let encodedValue = response.valueBase64 {
                guard let decoded = Data(base64Encoded: encodedValue) else {
                    throw ClipboardVaultError.invalidTrustState
                }
                return decoded
            }
            return nil
        }
    }

    private func validatedHelperLocked() throws -> URL {
        if let validatedHelperURL { return validatedHelperURL }
        let installed = URL(fileURLWithPath: Self.installedApplicationPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard running == installed else { throw ClipboardVaultError.keychain(errSecAuthFailed) }
        let helper = installed.appendingPathComponent(Self.helperRelativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let expected = installed.appendingPathComponent(Self.helperRelativePath)
            .standardizedFileURL
        guard helper == expected else { throw ClipboardVaultError.keychain(errSecAuthFailed) }

        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(helper as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw ClipboardVaultError.keychain(status)
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(
            Self.helperRequirement as CFString, [], &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw ClipboardVaultError.keychain(status)
        }
        status = SecStaticCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
        validatedHelperURL = helper
        return helper
    }

    private func validateRunningHelper(_ process: Process, expectedURL: URL) throws {
        let pid = process.processIdentifier
        var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
        let count = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard count > 0 else { throw ClipboardVaultError.keychain(errSecAuthFailed) }
        let actual = URL(fileURLWithPath: String(cString: pathBuffer))
            .resolvingSymlinksInPath().standardizedFileURL
        guard actual == expectedURL else { throw ClipboardVaultError.keychain(errSecAuthFailed) }

        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)]
        var status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else {
            throw ClipboardVaultError.keychain(status)
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(
            Self.helperRequirement as CFString, [], &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw ClipboardVaultError.keychain(status)
        }
        status = SecCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
    }
}

@available(*, unavailable, message: "Use the fixed HyperKeyBroker executable")
private final class KeychainClipboardVaultKeyProvider: ClipboardVaultKeyProviding {
    /// Legacy login-keychain items can retain or recreate their original `partition_id`
    /// ACL even after `SecKeychainItemSetAccess` is given a modified access object. Never
    /// mutate those records in place: authorize their value once, clone the exact bytes to
    /// a fresh account with an explicit certificate-backed SecAccess, then use only the
    /// new account. The legacy records are intentionally retained as rollback/recovery
    /// evidence; deleting them is a separate operation that is safe only after the new
    /// item and the on-disk library have both authenticated successfully.
    private static let installedApplicationPath = "/Applications/Hyper.app"
    private static let applicationIdentifier = "com.indincys.hyper"
    private static let designatedRequirement =
        "identifier \"com.indincys.hyper\" and "
        + "certificate leaf = h\"b9c36646f5ddd4cb7b116e5c3baf7b3e747b377e\""

    let service = ClipboardVault.keyService
    let account = ClipboardVault.keyAccount
    private let accessLock = NSLock()
    private let targetKeychain: SecKeychain?
    private let trustedApplicationOverride: SecTrustedApplication?
    private var didResolveStableApplication = false
    private var stableTrustedApplication: SecTrustedApplication?

    init(
        targetKeychain: SecKeychain? = nil,
        trustedApplication: SecTrustedApplication? = nil
    ) {
        self.targetKeychain = targetKeychain
        trustedApplicationOverride = trustedApplication
    }

    func loadKey() throws -> Data? {
        try accessLock.withLock {
            let application = try stableApplicationLocked()
            return try loadMigratingValueLocked(
                currentAccount: account,
                legacyAccount: ClipboardVault.legacyKeyAccount,
                trustedApplication: application
            )
        }
    }

    func createKey() throws -> Data {
        try accessLock.withLock {
            let application = try stableApplicationLocked()
            if let existing = try loadMigratingValueLocked(
                currentAccount: account,
                legacyAccount: ClipboardVault.legacyKeyAccount,
                trustedApplication: application
            ) {
                return existing
            }
            var bytes = Data(count: 32)
            let randomStatus = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard randomStatus == errSecSuccess else {
                throw ClipboardVaultError.keyGenerationFailed(randomStatus)
            }
            return try addStableValueLocked(
                bytes, account: account, trustedApplication: application
            )
        }
    }

    func loadTrustState() throws -> Data? {
        try accessLock.withLock {
            let application = try stableApplicationLocked()
            return try loadMigratingValueLocked(
                currentAccount: ClipboardVault.trustAccount,
                legacyAccount: ClipboardVault.legacyTrustAccount,
                trustedApplication: application
            )
        }
    }

    func storeTrustState(_ data: Data) throws {
        try accessLock.withLock {
            let application = try stableApplicationLocked()
            let slot = ClipboardVault.trustAccount
            guard let item = try copyItemReferenceLocked(account: slot) else {
                _ = try addStableValueLocked(
                    data, account: slot, trustedApplication: application
                )
                return
            }
            _ = try readStableValue(item, trustedApplication: application)
            var query = itemQuery(account: slot)
            addSearchList(to: &query)
            let status = SecItemUpdate(
                query as CFDictionary, [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw ClipboardVaultError.keychain(status)
            }
            guard try readStableValue(
                item, trustedApplication: application
            ) == data else { throw ClipboardVaultError.invalidTrustState }
        }
    }

    private func loadMigratingValueLocked(
        currentAccount: String,
        legacyAccount: String,
        trustedApplication: SecTrustedApplication
    ) throws -> Data? {
        if let current = try copyItemReferenceLocked(account: currentAccount) {
            return try readStableValue(current, trustedApplication: trustedApplication)
        }
        guard let legacy = try copyItemReferenceLocked(account: legacyAccount) else {
            return nil
        }

        // This is the sole operation that may display the legacy ACL authorization UI.
        // Cancellation fails closed before any new item exists. The old record is never
        // updated, deleted, or used as the target of SecKeychainItemSetAccess.
        let historicalBytes = try readContent(legacy)
        return try addStableValueLocked(
            historicalBytes,
            account: currentAccount,
            trustedApplication: trustedApplication
        )
    }

    private func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func addSearchList(to query: inout [String: Any]) {
        if let targetKeychain {
            query[kSecMatchSearchList as String] = [targetKeychain]
        }
    }

    private func copyItemReferenceLocked(account: String) throws -> SecKeychainItem? {
        var query = itemQuery(account: account)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        addSearchList(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
        guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else {
            throw ClipboardVaultError.keychain(errSecDecode)
        }
        return (result as! SecKeychainItem)
    }

    private func addStableValueLocked(
        _ data: Data,
        account: String,
        trustedApplication: SecTrustedApplication
    ) throws -> Data {
        let access = try makeStableAccess(trustedApplication: trustedApplication)
        var query = itemQuery(account: account)
        query.merge([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
            kSecAttrAccess as String: access,
            kSecReturnRef as String: true,
        ]) { _, new in new }
        if let targetKeychain {
            query[kSecUseKeychain as String] = targetKeychain
        }
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        let item: SecKeychainItem
        if status == errSecDuplicateItem {
            guard let existing = try copyItemReferenceLocked(account: account) else {
                throw ClipboardVaultError.keychain(status)
            }
            item = existing
        } else {
            guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
            guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else {
                throw ClipboardVaultError.keychain(errSecDecode)
            }
            item = result as! SecKeychainItem
        }

        // Adoption is complete only after the daemon-persisted value and ACL both match.
        // A duplicate from a concurrent launch is accepted only if it is byte-identical.
        let persisted = try readStableValue(item, trustedApplication: trustedApplication)
        guard persisted == data else { throw ClipboardVaultError.invalidTrustState }
        return persisted
    }

    private func makeStableAccess(
        trustedApplication: SecTrustedApplication
    ) throws -> SecAccess {
        var access: SecAccess?
        let status = SecAccessCreate(
            "Hyper Clipboard Vault" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard status == errSecSuccess, let access else {
            throw ClipboardVaultError.keychain(status)
        }
        // A fresh SecAccess has no partition ACL. Verify that before it is ever attached;
        // unlike the failed v1 repair, no existing access graph is edited or merged.
        try verifyStableAccess(access, trustedApplication: trustedApplication)
        return access
    }

    private func readStableValue(
        _ item: SecKeychainItem,
        trustedApplication: SecTrustedApplication
    ) throws -> Data {
        var access: SecAccess?
        let copied = SecKeychainItemCopyAccess(item, &access)
        guard copied == errSecSuccess, let access else {
            throw ClipboardVaultError.keychain(copied)
        }
        try verifyStableAccess(access, trustedApplication: trustedApplication)
        return try readContent(item)
    }

    private func verifyStableAccess(
        _ access: SecAccess, trustedApplication: SecTrustedApplication
    ) throws {
        if let partitions = SecAccessCopyMatchingACLList(
            access, kSecACLAuthorizationPartitionID
        ), CFArrayGetCount(partitions) != 0 {
            throw ClipboardVaultError.keychain(errSecAuthFailed)
        }
        guard let wanted = trustedApplicationData(trustedApplication),
              let decryptACLs = SecAccessCopyMatchingACLList(
                access, kSecACLAuthorizationDecrypt
              ), CFArrayGetCount(decryptACLs) == 1,
              let aclValue = (decryptACLs as [AnyObject]).first,
              CFGetTypeID(aclValue) == SecACLGetTypeID() else {
            throw ClipboardVaultError.keychain(errSecAuthFailed)
        }
        let acl = aclValue as! SecACL
        var applications: CFArray?
        var description: CFString?
        var selector = SecKeychainPromptSelector(rawValue: 0)
        let copied = SecACLCopyContents(acl, &applications, &description, &selector)
        guard copied == errSecSuccess,
              let applications, CFArrayGetCount(applications) == 1 else {
            throw ClipboardVaultError.keychain(
                copied == errSecSuccess ? errSecAuthFailed : copied
            )
        }
        let candidateValue = (applications as [AnyObject])[0]
        guard CFGetTypeID(candidateValue) == SecTrustedApplicationGetTypeID(),
              trustedApplicationData(candidateValue as! SecTrustedApplication) == wanted else {
            throw ClipboardVaultError.keychain(errSecAuthFailed)
        }
    }

    private func readContent(_ item: SecKeychainItem) throws -> Data {
        var length: UInt32 = 0
        var content: UnsafeMutableRawPointer?
        let status = SecKeychainItemCopyContent(item, nil, nil, &length, &content)
        guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
        defer { SecKeychainItemFreeContent(nil, content) }
        guard length == 0 || content != nil else {
            throw ClipboardVaultError.keychain(errSecDecode)
        }
        return content.map { Data(bytes: $0, count: Int(length)) } ?? Data()
    }

    private func trustedApplicationData(_ application: SecTrustedApplication) -> Data? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess,
              let data else { return nil }
        return data as Data
    }

    private func stableApplicationLocked() throws -> SecTrustedApplication {
        if !didResolveStableApplication {
            stableTrustedApplication = if let trustedApplicationOverride {
                trustedApplicationOverride
            } else {
                try makeStableInstalledApplicationTrust()
            }
            didResolveStableApplication = true
        }
        guard let stableTrustedApplication else {
            // A debug/ad-hoc copy must never mint or adopt the production master key.
            throw ClipboardVaultError.keychain(errSecAuthFailed)
        }
        return stableTrustedApplication
    }

    private func makeStableInstalledApplicationTrust() throws -> SecTrustedApplication? {
        let installedURL = URL(fileURLWithPath: Self.installedApplicationPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let runningURL = Bundle.main.bundleURL
            .resolvingSymlinksInPath().standardizedFileURL
        guard runningURL == installedURL,
              Bundle.main.bundleIdentifier == Self.applicationIdentifier else { return nil }

        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(installedURL as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw ClipboardVaultError.keychain(status)
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw ClipboardVaultError.keychain(status)
        }
        var requirementText: CFString?
        status = SecRequirementCopyString(requirement, [], &requirementText)
        guard status == errSecSuccess, let requirementText else {
            throw ClipboardVaultError.keychain(status)
        }
        let text = requirementText as String
        guard text.lowercased() == Self.designatedRequirement else {
            // An ad-hoc build's requirement is a cdhash. Never make that unstable identity
            // or a broader custom requirement the permanent ACL for the historical key.
            return nil
        }

        var trustedApplication: SecTrustedApplication?
        status = Self.installedApplicationPath.withCString {
            SecTrustedApplicationCreateFromPath($0, &trustedApplication)
        }
        guard status == errSecSuccess, let trustedApplication else {
            throw ClipboardVaultError.keychain(status)
        }
        return trustedApplication
    }
}

final class EphemeralClipboardVaultKeyProvider: ClipboardVaultKeyProviding {
    private static let lock = NSLock()
    private static var keys: [String: Data] = [:]
    private static var trustStates: [String: Data] = [:]

    let service = "com.indincys.hyper.clipboard.vault.ephemeral"
    let account: String

    init(scope: String = UUID().uuidString) { account = scope }
    func loadKey() throws -> Data? { Self.lock.withLock { Self.keys[account] } }

    func createKey() throws -> Data {
        try Self.lock.withLock {
            if let existing = Self.keys[account] { return existing }
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw ClipboardVaultError.keyGenerationFailed(status)
            }
            Self.keys[account] = bytes
            return bytes
        }
    }

    func loadTrustState() throws -> Data? { Self.lock.withLock { Self.trustStates[account] } }
    func storeTrustState(_ data: Data) throws {
        Self.lock.withLock { Self.trustStates[account] = data }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
