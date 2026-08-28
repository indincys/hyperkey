import Darwin
import Foundation
import Security

public enum HyperKeyBrokerAccounts {
    public static let service = "com.indincys.hyper.clipboard.vault"
    public static let key = "broker-master-key-v1"
    public static let trust = "broker-trust-state-v1"
    public static let legacyKeys = ["master-key-v2", "master-key-v1"]
    public static let legacyTrust = ["trust-state-v2", "trust-state-v1"]
}

public enum HyperKeyBrokerOperation: String, Codable {
    case loadKey, createKey, loadTrustState, storeTrustState
}

public struct HyperKeyBrokerRequest: Codable {
    public var operation: HyperKeyBrokerOperation
    public var valueBase64: String?

    public init(operation: HyperKeyBrokerOperation, valueBase64: String? = nil) {
        self.operation = operation
        self.valueBase64 = valueBase64
    }
}

public struct HyperKeyBrokerResponse: Codable {
    public var valueBase64: String?
    public var error: String?

    public init(value: Data?) {
        valueBase64 = value?.base64EncodedString()
        error = nil
    }

    public init(error: String) {
        valueBase64 = nil
        self.error = error
    }
}

public enum HyperKeyBrokerError: Error, Equatable {
    case security(OSStatus)
    case invalidData
    case parentRejected
}

/// Keychain implementation used only by the fixed broker executable. New records use the
/// creator ACL chosen by securityd on purpose: the creator is the separately built broker,
/// whose exact Mach-O and CDHash remain unchanged when the main Hyper executable changes.
public final class HyperKeyBrokerStore {
    private let targetKeychain: SecKeychain?
    private let lock = NSLock()

    public init(targetKeychain: SecKeychain? = nil) {
        self.targetKeychain = targetKeychain
    }

    public func loadKey() throws -> Data? {
        try lock.withLock {
            try loadMigrating(
                current: HyperKeyBrokerAccounts.key,
                legacy: HyperKeyBrokerAccounts.legacyKeys
            )
        }
    }

    public func createKey() throws -> Data {
        try lock.withLock {
            if let existing = try loadMigrating(
                current: HyperKeyBrokerAccounts.key,
                legacy: HyperKeyBrokerAccounts.legacyKeys
            ) { return existing }
            var value = Data(count: 32)
            let status = value.withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
            }
            guard status == errSecSuccess else { throw HyperKeyBrokerError.security(status) }
            return try addExact(value, account: HyperKeyBrokerAccounts.key)
        }
    }

    public func loadTrustState() throws -> Data? {
        try lock.withLock {
            try loadMigrating(
                current: HyperKeyBrokerAccounts.trust,
                legacy: HyperKeyBrokerAccounts.legacyTrust
            )
        }
    }

    public func storeTrustState(_ data: Data) throws {
        try lock.withLock {
            guard data.count <= 64 * 1024 else { throw HyperKeyBrokerError.invalidData }
            if try read(account: HyperKeyBrokerAccounts.trust, allowInteraction: false) == nil {
                _ = try addExact(data, account: HyperKeyBrokerAccounts.trust)
                return
            }
            var query = baseQuery(account: HyperKeyBrokerAccounts.trust)
            addSearchList(to: &query)
            let status = SecItemUpdate(
                query as CFDictionary, [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else { throw HyperKeyBrokerError.security(status) }
            guard try read(
                account: HyperKeyBrokerAccounts.trust, allowInteraction: false
            ) == data else {
                throw HyperKeyBrokerError.invalidData
            }
        }
    }

    private func loadMigrating(current: String, legacy: [String]) throws -> Data? {
        if let value = try read(account: current, allowInteraction: false) { return value }
        for account in legacy {
            // Only legacy adoption may display an authorization dialog. Once a broker
            // slot exists, every normal read is explicitly no-UI and fails closed if the
            // immutable broker creator partition ever stops matching.
            if let historical = try read(account: account, allowInteraction: true) {
                return try addExact(historical, account: current)
            }
        }
        return nil
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: HyperKeyBrokerAccounts.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func addSearchList(to query: inout [String: Any]) {
        if let targetKeychain {
            query[kSecMatchSearchList as String] = [targetKeychain]
        }
    }

    private func read(account: String, allowInteraction: Bool) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        addSearchList(to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HyperKeyBrokerError.security(status) }
        guard let data = result as? Data else { throw HyperKeyBrokerError.invalidData }
        return data
    }

    private func addExact(_ data: Data, account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        if let targetKeychain { query[kSecUseKeychain as String] = targetKeychain }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            throw HyperKeyBrokerError.security(status)
        }
        guard let persisted = try read(account: account, allowInteraction: false),
              persisted == data else {
            throw HyperKeyBrokerError.invalidData
        }
        return persisted
    }
}

public enum HyperKeyBrokerParentValidator {
    public static let parentExecutable = "/Applications/Hyper.app/Contents/MacOS/Hyper"
    public static let parentRequirement =
        "identifier \"com.indincys.hyper\" and "
        + "certificate leaf = H\"B9C36646F5DDD4CB7B116E5C3BAF7B3E747B377E\""

    public static func validateDirectParent() throws {
        let parentPID = getppid()
        var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
        let count = proc_pidpath(parentPID, &pathBuffer, UInt32(pathBuffer.count))
        guard count > 0 else { throw HyperKeyBrokerError.parentRejected }
        let actual = URL(fileURLWithPath: String(cString: pathBuffer))
            .resolvingSymlinksInPath().standardizedFileURL.path
        let expected = URL(fileURLWithPath: parentExecutable)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard actual == expected else { throw HyperKeyBrokerError.parentRejected }

        var parentCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: parentPID)]
        var status = SecCodeCopyGuestWithAttributes(
            nil, attributes as CFDictionary, [], &parentCode
        )
        guard status == errSecSuccess, let parentCode else {
            throw HyperKeyBrokerError.parentRejected
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(
            parentRequirement as CFString, [], &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw HyperKeyBrokerError.parentRejected
        }
        guard SecCodeCheckValidity(parentCode, [], requirement) == errSecSuccess else {
            throw HyperKeyBrokerError.parentRejected
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
