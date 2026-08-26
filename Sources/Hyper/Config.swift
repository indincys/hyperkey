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

/// How large the clipboard panel opens.
///
/// Three fixed sizes rather than a free width and height: the panel's row heights and
/// preview column are tuned per size, and a slider would hand out combinations where
/// neither reads well. The numbers are logical points — the window is laid out in
/// points, so they mean the same thing on a Retina display and a 1x one.
enum ClipPanelSize: String, CaseIterable {
    case compact
    case standard
    case large

    var dimensions: (width: CGFloat, height: CGFloat) {
        switch self {
        case .compact: return (360, 480)
        case .standard: return (400, 576)
        case .large: return (480, 680)
        }
    }

    var label: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .large: return "宽大"
        }
    }
}

/// Where on screen the panel opens. Whichever this is, it is placed on the screen the
/// mouse is on — a menu bar app that opened on the laptop display while you were working
/// on the external one would be worse than useless.
enum ClipPanelPosition: String, CaseIterable {
    case center
    case mouse
    case bottom

    var label: String {
        switch self {
        case .center: return "屏幕中央"
        case .mouse: return "鼠标所在位置"
        case .bottom: return "屏幕底部居中"
        }
    }
}

/// What ↩ does to the selected entry. The other of the two is always available on ⌘↩,
/// so this setting swaps the pair rather than taking one of them away.
enum ClipReturnAction: String, CaseIterable {
    case paste
    case copy

    var label: String {
        switch self {
        case .paste: return "直接粘贴"
        case .copy: return "仅复制并关闭面板"
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
    /// Bundle identifiers whose copies are never recorded, however they are marked.
    ///
    /// `skipConcealed` only catches what an application bothers to flag, and plenty of
    /// privacy-sensitive tools flag nothing at all. This is the blunt instrument for
    /// those: name the application and nothing it copies ever reaches the history.
    var ignoredApps: [String] = []
    /// Put the previous clipboard back after pasting. Off by default — after pasting
    /// something, having it still be on the clipboard is what people expect.
    var restoreAfterPaste = false
    var joinSeparator = "\n"
    /// Stored as raw strings for the same reason as `repeatPressRaw`: this is what the
    /// settings picker binds to and what gets written back, with the enum derived from
    /// it, so an unrecognised value in a hand-edited file degrades to the default
    /// instead of failing the whole decode.
    var panelSize = ClipPanelSize.standard.rawValue
    var panelPosition = ClipPanelPosition.center.rawValue
    var returnAction = ClipReturnAction.paste.rawValue

    var maxItemBytes: Int { maxItemMB * 1024 * 1024 }

    /// The panel's own logical size, so it can read one property instead of switching
    /// on the string itself.
    var panelDimensions: (width: CGFloat, height: CGFloat) {
        (ClipPanelSize(rawValue: panelSize) ?? .standard).dimensions
    }

    var panelPositionMode: ClipPanelPosition {
        ClipPanelPosition(rawValue: panelPosition) ?? .center
    }

    var returnActionMode: ClipReturnAction {
        ClipReturnAction(rawValue: returnAction) ?? .paste
    }
}

/// What a quick tap of the hyper key (pressed and released with no other key) does.
/// Defaults to `.none`; the plumbing exists so a new action is a config change.
enum TapAction {
    case none
    case key(CGKeyCode, CGEventFlags)
    /// Modifiers tapped with no key under them at all — `"ctrl+opt+cmd"`.
    ///
    /// There are shortcut recorders that accept nothing else: 豆包输入法's 免按模式 takes
    /// only fn / ⌘ / ⌥ / ⌃, single or combined, and drops anything with a key code in it.
    /// F18 is unrecordable there no matter how real we make it, so the tap has to arrive
    /// as bare modifiers instead.
    ///
    /// Safe to point at a subset of the hyper mask, because a tap injects no hyper
    /// modifiers at all — see `armModifierInjection`. ⌃⌥⌘ recorded elsewhere stays
    /// distinguishable from a hyper hold, which always carries Shift as well.
    case modifiers(CGEventFlags)

    init(rawValue: String) {
        let t = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "none" { self = .none; return }
        // "escape", "kc:53", "cmd+space", or modifiers alone: "ctrl+opt+cmd".
        let parts = t.split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        for (i, token) in parts.enumerated() {
            if let flag = TapAction.modifierFlag(token) {
                flags.insert(flag)
                continue
            }
            // Only the final token may be something other than a modifier: the key.
            guard i == parts.count - 1, let code = Keys.code(for: token) else {
                self = .none
                return
            }
            self = .key(code, flags)
            return
        }
        self = .modifiers(flags)
    }

    private static func modifierFlag(_ token: String) -> CGEventFlags? {
        switch token {
        case "cmd", "command": return .maskCommand
        case "ctrl", "control": return .maskControl
        case "opt", "option", "alt": return .maskAlternate
        case "shift": return .maskShift
        default: return nil
        }
    }
}

/// What pressing a binding does when its application is *already* frontmost.
///
/// Started life as a boolean ("hide it"), which covers the peek-and-go-back case but has
/// nothing to say to someone living in a browser with six windows open. Cycling that
/// application's own windows is the other thing a second press can usefully mean, so the
/// setting is an enum and the old boolean decodes into it.
enum RepeatPress: String {
    case hide
    case cycle
    case none
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
    /// How long a synthesized tap holds its key(s) down.
    ///
    /// **Not zero, and adjustable on purpose.** A press with no measurable duration is
    /// something no hardware can produce, and receivers that classify a press by how
    /// long it lasted — an input method deciding between "quick tap = toggle" and
    /// "hold = push-to-talk" — misread it. The state they land in is the sticky kind:
    /// they go on believing the key is still down and re-trigger on the next press
    /// instead of turning off. 70ms is an ordinary human tap and suits most receivers,
    /// but a modifier-only tap arrives as several events rather than one, and some
    /// receivers want longer before they will call it a tap. Hence a knob.
    var tapActionHoldMs = 70
    /// Kept as the raw string for the same reason as `tapActionRaw`: it is what the
    /// settings picker binds to and what gets written back, with the enum derived from it.
    var repeatPressRaw = RepeatPress.hide.rawValue
    var repeatPress: RepeatPress { RepeatPress(rawValue: repeatPressRaw) ?? .hide }
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
    var tapActionHoldMs: Int?
    var repeatPress: String?
    /// Superseded by `repeatPress`; still read so configs written before the setting grew
    /// a third option keep behaving the way their owner set them up.
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
    var ignoredApps: [String]?
    var restoreAfterPaste: Bool?
    var joinSeparator: String?
    var panelSize: String?
    var panelPosition: String?
    var returnAction: String?
}

enum ConfigStore {
    static let log = Logger(subsystem: Hyper.subsystem, category: "config")

    /// Injectable so tests can round-trip through a temporary directory instead of the
    /// user's real configuration — the same seam `ClipStore` and `PasteQueue` already
    /// have. Never set outside tests, so the app always reads `~/.config/hyper`.
    static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
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
        cfg.tapActionHoldMs = min(max(file.tapActionHoldMs ?? 70, 20), 500)
        // New key wins; the old boolean only speaks when the new key is absent.
        if let raw = file.repeatPress, let mode = RepeatPress(rawValue: raw) {
            cfg.repeatPressRaw = mode.rawValue
        } else if let legacy = file.toggleHideIfFrontmost {
            cfg.repeatPressRaw = (legacy ? RepeatPress.hide : .none).rawValue
        }
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
            // Hand-edited files are the norm here, so drop blanks and duplicates rather
            // than letting them sit in the list where they can never match anything.
            if let ignored = stored.ignoredApps {
                var seen = Set<String>()
                clipboard.ignoredApps = ignored
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            clipboard.restoreAfterPaste = stored.restoreAfterPaste ?? clipboard.restoreAfterPaste
            clipboard.joinSeparator = stored.joinSeparator ?? clipboard.joinSeparator
            // A value nobody recognises falls back to the default, the way `repeatPress`
            // does — a typo in one key must not change what the panel does elsewhere.
            if let raw = stored.panelSize, let size = ClipPanelSize(rawValue: raw) {
                clipboard.panelSize = size.rawValue
            }
            if let raw = stored.panelPosition, let position = ClipPanelPosition(rawValue: raw) {
                clipboard.panelPosition = position.rawValue
            }
            if let raw = stored.returnAction, let action = ClipReturnAction(rawValue: raw) {
                clipboard.returnAction = action.rawValue
            }
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
            "ignoredApps": config.clipboard.ignoredApps,
            "restoreAfterPaste": config.clipboard.restoreAfterPaste,
            "joinSeparator": config.clipboard.joinSeparator,
            "panelSize": config.clipboard.panelSize,
            "panelPosition": config.clipboard.panelPosition,
            "returnAction": config.clipboard.returnAction,
        ]

        let document: [String: Any] = [
            "enabled": config.enabled,
            "debug": config.debug,
            "tapAction": config.tapActionRaw,
            "tapThresholdMs": config.tapThresholdMs,
            "tapActionHoldMs": config.tapActionHoldMs,
            "repeatPress": config.repeatPressRaw,
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
      "repeatPress": "hide",
      "clipboardBindingsSeeded": true,
      "clipboard": {
        "enabled": true,
        "retentionDays": 30,
        "maxItems": 1000,
        "maxItemMB": 20,
        "recordImages": true,
        "skipConcealed": true,
        "skipTransient": true,
        "ignoredApps": [],
        "restoreAfterPaste": false,
        "joinSeparator": "\\n",
        "panelSize": "standard",
        "panelPosition": "center",
        "returnAction": "paste"
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
