import Darwin
import Foundation
import HyperKeyBrokerSupport

private func fail(_ code: String) -> Never {
    let response = HyperKeyBrokerResponse(error: code)
    if let encoded = try? JSONEncoder().encode(response) {
        FileHandle.standardOutput.write(encoded)
    }
    exit(EXIT_FAILURE)
}

do {
    try HyperKeyBrokerParentValidator.validateDirectParent()
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 128 * 1024 else { fail("request-too-large") }
    let request = try JSONDecoder().decode(HyperKeyBrokerRequest.self, from: input)
    let store = HyperKeyBrokerStore()
    let value: Data?
    switch request.operation {
    case .loadKey:
        value = try store.loadKey()
    case .createKey:
        value = try store.createKey()
    case .loadTrustState:
        value = try store.loadTrustState()
    case .storeTrustState:
        guard let encoded = request.valueBase64,
              let trust = Data(base64Encoded: encoded), trust.count <= 64 * 1024 else {
            fail("invalid-trust-state")
        }
        try store.storeTrustState(trust)
        value = nil
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(HyperKeyBrokerResponse(value: value)))
} catch HyperKeyBrokerError.parentRejected {
    fail("parent-rejected")
} catch {
    fail("broker-operation-failed")
}
