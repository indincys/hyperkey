import CryptoKit
import Foundation
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
    case empty, legacyPlaintext, encryptedV2, invalidOrMixed
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
    static let keyAccount = "master-key-v1"
    static let trustAccount = "trust-state-v1"

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

    init(provider: ClipboardVaultKeyProviding = KeychainClipboardVaultKeyProvider()) {
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
                    guard library == .legacyPlaintext || library == .encryptedV2 else {
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

    static func plaintextHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private final class KeychainClipboardVaultKeyProvider: ClipboardVaultKeyProviding {
    let service = ClipboardVault.keyService
    let account = ClipboardVault.keyAccount

    func loadKey() throws -> Data? { try read(account: account) }

    func createKey() throws -> Data {
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw ClipboardVaultError.keyGenerationFailed(randomStatus)
        }
        do {
            try add(bytes, account: account)
            return bytes
        } catch ClipboardVaultError.keychain(errSecDuplicateItem) {
            guard let existing = try loadKey() else {
                throw ClipboardVaultError.keychain(errSecDuplicateItem)
            }
            return existing
        }
    }

    func loadTrustState() throws -> Data? { try read(account: ClipboardVault.trustAccount) }

    func storeTrustState(_ data: Data) throws {
        let slot = ClipboardVault.trustAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot,
        ]
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound { try add(data, account: slot); return }
        guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
    }

    private func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
        guard let data = result as? Data else { throw ClipboardVaultError.keychain(errSecDecode) }
        return data
    }

    private func add(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClipboardVaultError.keychain(status) }
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
