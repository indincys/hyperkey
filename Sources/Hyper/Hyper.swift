import Foundation

enum Hyper {
    static let subsystem = "com.indincys.hyper"
    static let version = "1.3.6"

    /// Stamped into `.eventSourceUserData` on every keyboard event we synthesize, so
    /// the tap recognises its own output and passes it through untouched instead of
    /// recursing. Shared because the clipboard paster synthesizes events too, and both
    /// sides must agree on the value.
    static let syntheticEventMarker: Int64 = 0x4859_5045  // 'HYPE'
}
