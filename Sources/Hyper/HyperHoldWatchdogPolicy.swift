import Foundation

/// Pure decision layer for the stuck-Hyper safety watchdog.
///
/// Keeping this separate from the event tap makes the safety contract executable in
/// tests: a readable physical down state must keep an arbitrarily long hold alive; a
/// readable up state releases immediately; missing raw-HID access gets a finite grace
/// period rather than being mistaken for a key-up.
enum HyperHoldWatchdogPolicy {
    static let unknownStateTimeout: TimeInterval = 10

    /// The ceiling that applies even to a confidently readable "still down".
    ///
    /// A readable down state is trusted, but it is not infallible: a HID element can
    /// latch at 1 and stay there when a device is yanked mid-press or a Bluetooth
    /// keyboard drops out while the key is held, and the raw element has no key-up to
    /// send. That reads as an honest, indefinite hold — four modifiers latched and every
    /// keystroke eaten as part of a chord, with no way out but quitting the app.
    ///
    /// 30 seconds is far past any ordinary hold and far short of leaving the machine
    /// unusable. Releasing early costs the user one repeated press.
    static let absoluteHoldLimit: TimeInterval = 30

    /// The same ceiling while a peek is on screen.
    ///
    /// Peek's whole contract is "it stays up as long as you hold the keys" — the user is
    /// *reading* the application they pulled forward, and half a minute of that is not
    /// unusual. Cutting them off at 30s would hide the window mid-sentence and put the
    /// previous application back, which reads as the feature breaking rather than as a
    /// safety net. The ceiling is still there, four times further out, because a latched
    /// HID element during a peek is the same hazard as during any other hold.
    static let peekHoldLimit: TimeInterval = 120

    static func holdLimit(peekActive: Bool) -> TimeInterval {
        peekActive ? peekHoldLimit : absoluteHoldLimit
    }

    static func shouldRelease(
        physicalKeyDown: Bool?, heldFor: TimeInterval, peekActive: Bool = false
    ) -> Bool {
        if heldFor >= holdLimit(peekActive: peekActive) { return true }
        switch physicalKeyDown {
        case true: return false
        case false: return true
        case nil: return heldFor >= unknownStateTimeout
        }
    }
}
