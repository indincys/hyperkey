import CoreGraphics
import Foundation
import os

/// Something the app does itself, as opposed to an application it launches. Written
/// in the config with an `@` prefix, which no bundle identifier or path can start with.
enum BuiltinAction: String, CaseIterable {
    case clipboardPanel = "@clipboard"
    case clipEnqueue = "@clip-enqueue"
    case clipPasteNext = "@clip-paste-next"

    var displayName: String {
        switch self {
        case .clipboardPanel: return "剪贴板面板"
        case .clipEnqueue: return "复制并加入队列"
        case .clipPasteNext: return "粘贴队列下一条"
        }
    }

    var detail: String {
        switch self {
        case .clipboardPanel: return "打开剪贴板历史，搜索、单击即粘贴"
        case .clipEnqueue: return "把当前选中的内容复制并追加到批量队列"
        case .clipPasteNext: return "依次吐出队列里的下一条；队列为空时粘贴最近一条"
        }
    }

    var symbolName: String {
        switch self {
        case .clipboardPanel: return "clipboard"
        case .clipEnqueue: return "text.append"
        case .clipPasteNext: return "arrow.down.doc"
        }
    }
}

enum LaunchTarget: CustomStringConvertible {
    case bundleID(String)
    case path(String)
    case action(BuiltinAction)

    init(rawValue: String) {
        if rawValue.hasPrefix("@"), let action = BuiltinAction(rawValue: rawValue) {
            self = .action(action)
        } else if rawValue.hasPrefix("/") || rawValue.hasPrefix("~") || rawValue.hasSuffix(".app") {
            self = .path(rawValue)
        } else {
            self = .bundleID(rawValue)
        }
    }

    var description: String {
        switch self {
        case .bundleID(let id): return id
        case .path(let p): return p
        case .action(let action): return action.rawValue
        }
    }
}

/// Everything the clipboard feature reads out of the config file.
struct ClipboardSettings: Equatable {
    var enabled = true
    /// Rolling eviction, not a periodic wipe: age and count, whichever bites first.
    /// Pinned entries are exempt from both.
    var retentionDays = 30
    var maxItems = 1000
    /// Per-entry cap. Above this only the metadata is kept, so one enormous copy can
    /// never take the history's disk budget with it.
    var maxItemMB = 20
    var recordImages = true
    /// Skip anything a password manager marked as a secret. On by default; this is
    /// what makes leaving a clipboard history running safe.
    var skipConcealed = true
    var skipTransient = true
    /// Put the previous clipboard back after pasting. Off by default — after pasting
    /// something, having it still be on the clipboard is what people expect.
    var restoreAfterPaste = false
    var joinSeparator = "\n"

    var maxItemBytes: Int { maxItemMB * 1024 * 1024 }
}

/// What a quick tap of the hyper key (pressed and released with no other key) does.
/// Defaults to `.none`; the plumbing exists so a new action is a config change.
enum TapAction {
    case none
    case key(CGKeyCode, CGEventFlags)

    init(rawValue: String) {
        let t = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "none" { self = .none; return }
        // "escape", "kc:53", or "cmd+space" style
        var flags: CGEventFlags = []
        var keyToken = t
        if t.contains("+") {
            let parts = t.split(separator: "+").map(String.init)
            keyToken = parts.last ?? ""
            for m in parts.dropLast() {
                switch m {
                case "cmd", "command": flags.insert(.maskCommand)
                case "ctrl", "control": flags.insert(.maskControl)
                case "opt", "option", "alt": flags.insert(.maskAlternate)
                case "shift": flags.insert(.maskShift)
                default: break
                }
            }
        }
        guard let code = Keys.code(for: keyToken) else { self = .none; return }
        self = .key(code, flags)
    }
}

struct Config {
    var enabled = true
    /// Logs every key event's *key code* at debug level. Off by default: it is a
    /// diagnostic for "nothing happens when I press the key", not something to leave on.
    var debug = false
    var tapAction: TapAction = .none
    /// Kept verbatim so writing the file back does not rewrite the user's spelling.
    var tapActionRaw = "none"
    var tapThresholdMs = 200
    var toggleHideIfFrontmost = true
    var clipboard = ClipboardSettings()
    var clipboardBindingsSeeded = false
    var bindings: [CGKeyCode: LaunchTarget] = [:]

    /// The bindings as written, in display order. The source of truth when saving;
    /// `bindings` is the lookup table derived from it.
    var bindingNames: [(key: String, target: String)] = []

    mutating func setBindings(_ pairs: [(key: String, target: String)]) {
        bindingNames = pairs.sorted { $0.key < $1.key }
        bindings = [:]
        for pair in bindingNames {
            guard let code = Keys.code(for: pair.key) else { continue }
            bindings[code] = LaunchTarget(rawValue: pair.target)
        }
    }

    /// Preferred key for each built-in action on a fresh install. Chosen from keys the
    /// shipped defaults leave free, so a new user gets all three without a collision.
    static let clipboardDefaultKeys: [(key: String, action: BuiltinAction)] = [
        ("space", .clipboardPanel),
        ("q", .clipEnqueue),
        ("v", .clipPasteNext),
    ]

    /// Adds the clipboard bindings to an existing configuration, but only on keys that
    /// are still free.
    ///
    /// An upgrade must never repurpose a key someone already uses — finding that
    /// Hyper+C stopped opening Chrome would be worse than not getting the new feature.
    /// Anything that collides is simply skipped and reported, and the settings window
    /// is where the user can then bind it deliberately.
    mutating func seedClipboardBindings() -> [BuiltinAction] {
        var taken = Set(bindingNames.map(\.key))
        var pairs = bindingNames
        var skipped: [BuiltinAction] = []

        for (key, action) in Config.clipboardDefaultKeys {
            guard !pairs.contains(where: { $0.target == action.rawValue }) else { continue }
            guard !taken.contains(key) else {
                skipped.append(action)
                continue
            }
            taken.insert(key)
            pairs.append((key: key, target: action.rawValue))
        }

        setBindings(pairs)
        clipboardBindingsSeeded = true
        return skipped
    }
}

private struct ConfigFile: Codable {
    var enabled: Bool?
    var debug: Bool?
    var tapAction: String?
    var tapThresholdMs: Int?
    var toggleHideIfFrontmost: Bool?
    var clipboard: ClipboardFile?
    var bindings: [String: String]?
    /// Set once the built-in clipboard bindings have been offered to an existing
    /// install, so an upgrade adds them exactly once and never fights a user who
    /// deliberately removed them.
    var clipboardBindingsSeeded: Bool?
}

private struct ClipboardFile: Codable {
    var enabled: Bool?
    var retentionDays: Int?
    var maxItems: Int?
    var maxItemMB: Int?
    var recordImages: Bool?
    var skipConcealed: Bool?
    var skipTransient: Bool?
    var restoreAfterPaste: Bool?
    var joinSeparator: String?
}

enum ConfigStore {
    static let log = Logger(subsystem: Hyper.subsystem, category: "config")

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hyper", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("config.json") }

    /// Returns nil when the file exists but cannot be parsed, so the caller can keep
    /// the bindings it already has instead of silently dropping every shortcut.
    static func load() -> Config? {
        guard let data = try? Data(contentsOf: url) else {
            log.info("no config at \(url.path, privacy: .public), writing default")
            writeDefaultIfMissing()
            return decode(defaultJSON.data(using: .utf8)!)
        }
        guard let cfg = decode(data) else {
            log.error("config at \(url.path, privacy: .public) is not valid JSON — keeping previous bindings")
            return nil
        }
        return cfg
    }

    private static func decode(_ data: Data) -> Config? {
        guard let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return nil }
        var cfg = Config()
        cfg.enabled = file.enabled ?? true
        cfg.debug = file.debug ?? false
        cfg.tapActionRaw = file.tapAction ?? "none"
        cfg.tapAction = TapAction(rawValue: cfg.tapActionRaw)
        cfg.tapThresholdMs = file.tapThresholdMs ?? 200
        cfg.toggleHideIfFrontmost = file.toggleHideIfFrontmost ?? true
        cfg.clipboardBindingsSeeded = file.clipboardBindingsSeeded ?? false

        var clipboard = ClipboardSettings()
        if let stored = file.clipboard {
            clipboard.enabled = stored.enabled ?? clipboard.enabled
            clipboard.retentionDays = max(1, stored.retentionDays ?? clipboard.retentionDays)
            clipboard.maxItems = max(10, stored.maxItems ?? clipboard.maxItems)
            clipboard.maxItemMB = max(1, stored.maxItemMB ?? clipboard.maxItemMB)
            clipboard.recordImages = stored.recordImages ?? clipboard.recordImages
            clipboard.skipConcealed = stored.skipConcealed ?? clipboard.skipConcealed
            clipboard.skipTransient = stored.skipTransient ?? clipboard.skipTransient
            clipboard.restoreAfterPaste = stored.restoreAfterPaste ?? clipboard.restoreAfterPaste
            clipboard.joinSeparator = stored.joinSeparator ?? clipboard.joinSeparator
        }
        cfg.clipboard = clipboard

        for (rawKey, rawTarget) in file.bindings ?? [:] {
            guard let code = Keys.code(for: rawKey) else {
                log.error("unknown key '\(rawKey, privacy: .public)' in config — skipped")
                continue
            }
            cfg.bindings[code] = LaunchTarget(rawValue: rawTarget)
            cfg.bindingNames.append((key: rawKey, target: rawTarget))
        }
        cfg.bindingNames.sort { $0.key < $1.key }
        return cfg
    }

    /// Writes atomically so a crash mid-write cannot leave a truncated file that the
    /// next launch would reject.
    @discardableResult
    static func save(_ config: Config) -> Bool {
        var bindings: [String: String] = [:]
        for pair in config.bindingNames { bindings[pair.key] = pair.target }

        let clipboard: [String: Any] = [
            "enabled": config.clipboard.enabled,
            "retentionDays": config.clipboard.retentionDays,
            "maxItems": config.clipboard.maxItems,
            "maxItemMB": config.clipboard.maxItemMB,
            "recordImages": config.clipboard.recordImages,
            "skipConcealed": config.clipboard.skipConcealed,
            "skipTransient": config.clipboard.skipTransient,
            "restoreAfterPaste": config.clipboard.restoreAfterPaste,
            "joinSeparator": config.clipboard.joinSeparator,
        ]

        let document: [String: Any] = [
            "enabled": config.enabled,
            "debug": config.debug,
            "tapAction": config.tapActionRaw,
            "tapThresholdMs": config.tapThresholdMs,
            "toggleHideIfFrontmost": config.toggleHideIfFrontmost,
            "clipboard": clipboard,
            "clipboardBindingsSeeded": config.clipboardBindingsSeeded,
            "bindings": bindings,
        ]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: document, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            log.info("config saved: \(bindings.count) bindings")
            return true
        } catch {
            log.error("config save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func writeDefaultIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? defaultJSON.data(using: .utf8)?.write(to: url)
    }

    static let defaultJSON = """
    {
      "enabled": true,
      "tapAction": "none",
      "tapThresholdMs": 200,
      "toggleHideIfFrontmost": true,
      "clipboardBindingsSeeded": true,
      "clipboard": {
        "enabled": true,
        "retentionDays": 30,
        "maxItems": 1000,
        "maxItemMB": 20,
        "recordImages": true,
        "skipConcealed": true,
        "skipTransient": true,
        "restoreAfterPaste": false,
        "joinSeparator": "\\n"
      },
      "bindings": {
        "a": "com.anthropic.claudefordesktop",
        "c": "com.google.Chrome",
        "d": "company.thebrowser.dia",
        "f": "com.apple.finder",
        "l": "com.electron.lark",
        "s": "com.apple.Safari",
        "t": "com.mitchellh.ghostty",
        "w": "com.tencent.xinWeChat",
        "x": "com.apple.dt.Xcode",
        "space": "@clipboard",
        "q": "@clip-enqueue",
        "v": "@clip-paste-next"
      }
    }
    """
}

/// Watches the config file and calls `onChange` on the main queue.
/// Re-arms after atomic saves (editors write a temp file and rename over the original,
/// which invalidates the original file descriptor).
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        arm()
    }

    private func arm() {
        disarm()
        fd = open(ConfigStore.url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File may not exist yet; retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.arm() }
            }
        }
        src.setCancelHandler { [fd] in if fd >= 0 { close(fd) } }
        src.resume()
        source = src
    }

    private func disarm() {
        source?.cancel()
        source = nil
        fd = -1
    }

    deinit { disarm() }
}
