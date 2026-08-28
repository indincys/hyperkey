#!/usr/bin/env swift

import CryptoKit
import Foundation
import Security

private struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func statusMessage(_ operation: String, _ status: OSStatus) -> ToolFailure {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return ToolFailure("\(operation): \(detail) (\(status))")
}

private func certificateSHA1(_ certificate: SecCertificate) -> String {
    Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }
        .joined()
}

private func identity(named name: String, expectedSHA1: String) throws -> SecIdentity {
    let query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { throw statusMessage("find signing identities", status) }

    let values: [AnyObject]
    if let array = result as? [AnyObject] { values = array }
    else if let result { values = [result] }
    else { values = [] }

    for value in values where CFGetTypeID(value) == SecIdentityGetTypeID() {
        let candidate = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(candidate, &certificate) == errSecSuccess,
              let certificate else { continue }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
              commonName as String? == name else { continue }
        let actualSHA1 = certificateSHA1(certificate)
        guard actualSHA1 == expectedSHA1.uppercased() else {
            throw ToolFailure(
                "identity \(name) has SHA-1 \(actualSHA1), expected \(expectedSHA1.uppercased())"
            )
        }
        return candidate
    }
    throw ToolFailure("signing identity not found: \(name)")
}

private func privateKeyItem(for identity: SecIdentity) throws -> SecKeychainItem {
    var key: SecKey?
    let status = SecIdentityCopyPrivateKey(identity, &key)
    guard status == errSecSuccess, let key else {
        throw statusMessage("resolve signing private key", status)
    }
    return unsafeBitCast(key, to: SecKeychainItem.self)
}

private func partitionACLs(in access: SecAccess) throws -> [SecACL] {
    guard let values = SecAccessCopyMatchingACLList(
        access, kSecACLAuthorizationPartitionID
    ) else { return [] }
    return (values as [AnyObject]).compactMap { value in
        guard CFGetTypeID(value) == SecACLGetTypeID() else { return nil }
        return (value as! SecACL)
    }
}

private func partitionDescription(_ acl: SecACL) throws -> String {
    var applications: CFArray?
    var description: CFString?
    var selector = SecKeychainPromptSelector(rawValue: 0)
    let status = SecACLCopyContents(acl, &applications, &description, &selector)
    guard status == errSecSuccess else { throw statusMessage("read partition ACL", status) }
    return description as String? ?? ""
}

private func hexData(_ value: String) -> Data? {
    guard value.count.isMultiple(of: 2), !value.isEmpty else { return nil }
    var data = Data(capacity: value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

private func partitionIdentifiers(_ description: String) -> [String] {
    if let data = hexData(description),
       let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
       let dictionary = propertyList as? [String: Any],
       let partitions = dictionary["Partitions"] as? [String] {
        return partitions
    }
    return description
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private func includesCodesignPartition(_ description: String) -> Bool {
    partitionIdentifiers(description).contains("apple:")
}

private func repair(_ item: SecKeychainItem, access: SecAccess, acls: [SecACL]) throws {
    let desired = "apple-tool:,apple:"
    if acls.isEmpty {
        var created: SecACL?
        let status = SecACLCreateWithSimpleContents(
            access, nil, desired as CFString,
            SecKeychainPromptSelector(rawValue: 0), &created
        )
        guard status == errSecSuccess, created != nil else {
            throw statusMessage("create partition ACL", status)
        }
        let authStatus = SecACLUpdateAuthorizations(
            created!, [kSecACLAuthorizationPartitionID] as CFArray
        )
        guard authStatus == errSecSuccess else {
            throw statusMessage("authorize partition ACL", authStatus)
        }
    } else {
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector(rawValue: 0)
            let copied = SecACLCopyContents(acl, &applications, &description, &selector)
            guard copied == errSecSuccess else {
                throw statusMessage("read partition ACL", copied)
            }
            let updated = SecACLSetContents(acl, applications, desired as CFString, selector)
            guard updated == errSecSuccess else {
                throw statusMessage("update partition ACL", updated)
            }
        }
    }
    let status = SecKeychainItemSetAccess(item, access)
    guard status == errSecSuccess else { throw statusMessage("persist private-key ACL", status) }
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, ["--check", "--repair"].contains(arguments[1]) else {
        throw ToolFailure(
            "usage: repair-signing-key-access.swift --check|--repair <identity> <certificate-sha1>"
        )
    }
    let signingIdentity = try identity(named: arguments[2], expectedSHA1: arguments[3])
    let item = try privateKeyItem(for: signingIdentity)
    var access: SecAccess?
    var status = SecKeychainItemCopyAccess(item, &access)
    guard status == errSecSuccess, let access else {
        throw statusMessage("read private-key access", status)
    }
    var acls = try partitionACLs(in: access)
    var descriptions = try acls.map(partitionDescription)
    if descriptions.contains(where: includesCodesignPartition) {
        print("signing key already permits the apple: codesign partition")
        exit(EXIT_SUCCESS)
    }
    guard arguments[1] == "--repair" else {
        let identifiers = descriptions.flatMap(partitionIdentifiers)
        let found = identifiers.isEmpty ? "none" : identifiers.joined(separator: ",")
        throw ToolFailure(
            "signing key is missing the apple: codesign partition (found: \(found))"
        )
    }

    try repair(item, access: access, acls: acls)
    var verifiedAccess: SecAccess?
    status = SecKeychainItemCopyAccess(item, &verifiedAccess)
    guard status == errSecSuccess, let verifiedAccess else {
        throw statusMessage("verify private-key access", status)
    }
    acls = try partitionACLs(in: verifiedAccess)
    descriptions = try acls.map(partitionDescription)
    guard descriptions.contains(where: includesCodesignPartition) else {
        throw ToolFailure("private-key ACL update did not persist")
    }
    print("added the apple: codesign partition to \(arguments[2])")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(EXIT_FAILURE)
}
