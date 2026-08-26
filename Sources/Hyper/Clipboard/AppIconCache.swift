import AppKit

/// Icons for the applications entries were copied from, and for the files a file entry
/// points at.
///
/// Both lookups go through Launch Services and end in decoding an `.icns`, which is far
/// too much work to repeat per row: SwiftUI rebuilds every visible row on each
/// keystroke, each hover and each 30-second clock tick, so an uncached `icon(forFile:)`
/// in `body` would be paid dozens of times a second. Memoising for the lifetime of the
/// process costs a few hundred kilobytes and makes the lookup free after the first row
/// that needs it.
///
/// Main-thread only, like everything else the panel touches — `NSCache` is thread-safe,
/// but `misses` is not, and `NSWorkspace` prefers the main thread anyway.
final class AppIconCache {
    static let shared = AppIconCache()

    private let byBundleID = NSCache<NSString, NSImage>()
    private let byPath = NSCache<NSString, NSImage>()

    /// Bundle identifiers Launch Services could not resolve — an application that has
    /// since been deleted, or a copy that came from something with no bundle at all.
    /// `NSCache` cannot hold "no answer", and this is exactly the case that would
    /// otherwise pay for a full lookup on every redraw.
    private var misses: Set<String> = []

    private init() {
        byBundleID.countLimit = 64
        byPath.countLimit = 256
    }

    /// The icon of the application an entry was copied from, or nil when it cannot be
    /// found — the caller falls back to the entry's kind glyph.
    func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty, !misses.contains(bundleID) else { return nil }
        let key = bundleID as NSString
        if let cached = byBundleID.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        byBundleID.setObject(icon, forKey: key)
        return icon
    }

    /// The Finder icon for a path. Always returns something: for a path that no longer
    /// exists the workspace hands back the generic document icon, which is the right
    /// picture next to a row that says the file is gone.
    func fileIcon(path: String) -> NSImage {
        let key = path as NSString
        if let cached = byPath.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        byPath.setObject(icon, forKey: key)
        return icon
    }
}
