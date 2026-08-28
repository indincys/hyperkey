import Foundation

/// Pure decision layer for the stuck-Hyper safety watchdog.
///
/// Keeping this separate from the event tap makes the safety contract executable in
/// tests: a readable physical down state must keep an arbitrarily long hold alive; a
/// readable up state releases immediately; missing raw-HID access gets a finite grace
/// period rather than being mistaken for a key-up.
enum HyperHoldWatchdogPolicy {
    static let unknownStateTimeout: TimeInterval = 10

    static func shouldRelease(physicalKeyDown: Bool?, heldFor: TimeInterval) -> Bool {
        switch physicalKeyDown {
        case true: return false
        case false: return true
        case nil: return heldFor >= unknownStateTimeout
        }
    }
}
