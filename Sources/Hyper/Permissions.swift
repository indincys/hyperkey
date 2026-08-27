import Cocoa

enum Permissions {
    enum AccessibilityStatus: Equatable {
        case granted
        case denied
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// A value-returning check used at the paste transaction boundary. Keeping the
    /// evaluator injectable lets tests exercise a revoked grant without mutating the
    /// machine's real Accessibility database.
    static func accessibilityStatus(
        using evaluator: () -> Bool = { AXIsProcessTrusted() }
    ) -> AccessibilityStatus {
        evaluator() ? .granted : .denied
    }

    /// Asks the system to show the "grant accessibility access" prompt.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
