import CoreGraphics
import Foundation
import os

/// Something the app does itself, as opposed to an application it launches. Written
/// in the config with an `@` prefix, which no bundle identifier or path can start with.
enum BuiltinAction: String, CaseIterable, Codable {
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

enum LaunchTarget: CustomStringConvertible, Equatable {
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

/// What Hyper may retain from one application's clipboard writes.
///
/// The raw values are part of the hand-edited JSON format. Keep them stable: an old
/// config has to remain useful after the settings UI grows controls for these rules.
enum ClipboardApplicationRule: String, CaseIterable {
    /// Never read or retain the application's clipboard content.
    case ignore
    /// Retain only an interoperable plain-text representation.
    case textOnly
    /// Retain ordinary content, but reject image clipboard items.
    case noImages
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
    /// High-confidence text risks that do not carry a system marker still need a finite
    /// lifecycle. Five minutes is long enough to use a password/OTP and short enough to
    /// avoid leaving it in a searchable history for the rest of the retention window.
    var sensitiveHandling = SensitiveClipboardHandling.expire
    var sensitiveTTLMinutes = 5
    /// A temporary, persisted privacy pause. A past date is equivalent to nil and is
    /// deliberately harmless if an older config writer leaves it behind.
    var pauseUntil: Date?
    /// Per-bundle capture rules. A dictionary makes one application have exactly one
    /// unambiguous policy and gives future settings UI a model it can edit directly.
    var applicationRules: [String: ClipboardApplicationRule] = [:]

    /// Compatibility surface for the existing ignore-app settings UI and old callers.
    /// Old JSON is migrated into `applicationRules`; saves still emit `ignoredApps` so
    /// downgrading to a pre-rule build does not silently lose the strongest rule.
    var ignoredApps: [String] {
        get {
            applicationRules.compactMap { $0.value == .ignore ? $0.key : nil }.sorted()
        }
        set {
            applicationRules = applicationRules.filter { $0.value != .ignore }
            for bundleID in newValue { applicationRules[bundleID] = .ignore }
        }
    }
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
enum TapAction: Equatable {
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
enum RepeatPress: String, Equatable {
    case hide
    case cycle
    case none
}

struct Config: Equatable {
    static let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

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
    /// Named shortcut contexts. The active profile is materialized into `bindings` in
    /// one step, so the event tap never observes a half-switched lookup table.
    var profiles: [ShortcutProfile] = [
        ShortcutProfile(id: Config.defaultProfileID, name: "Default")
    ]
    var activeProfileID: UUID? = Config.defaultProfileID
    var bindings: [CGKeyCode: LaunchTarget] = [:]

    /// The bindings as written, in display order. The source of truth when saving;
    /// `bindings` is the lookup table derived from it.
    var bindingNames: [(key: String, target: String)] = []

    var activeProfile: ShortcutProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    mutating func setBindings(_ pairs: [(key: String, target: String)]) {
        let old = activeProfile?.allBindings ?? []
        var reusable = Dictionary(grouping: old) { "\($0.key.lowercased())\u{0}\($0.target)" }
        let durable = pairs.map { pair -> ShortcutBinding in
            let lookup = "\(pair.key.lowercased())\u{0}\(pair.target)"
            let id = reusable[lookup]?.isEmpty == false ? reusable[lookup]!.removeFirst().id : UUID()
            return ShortcutBinding(id: id, key: pair.key, target: pair.target)
        }
        setProfileBindings(durable)
    }

    mutating func setProfileBindings(_ newBindings: [ShortcutBinding]) {
        ensureProfileInvariant()
        guard let activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        profiles[index].replaceBindings(newBindings)
        rebuildRuntimeBindings()
    }

    /// Switches the entire runtime lookup or does nothing. Callers pass the resulting
    /// Config value to HyperTap as one value assignment after persistence succeeds.
    @discardableResult
    mutating func activateProfile(_ id: UUID) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        activeProfileID = id
        rebuildRuntimeBindings()
        return true
    }

    mutating func rebuildRuntimeBindings() {
        bindingNames = (activeProfile?.allBindings ?? [])
            .sorted { lhs, rhs in
                let lk = Keys.canonicalName(for: lhs.key) ?? lhs.key.lowercased()
                let rk = Keys.canonicalName(for: rhs.key) ?? rhs.key.lowercased()
                if lk != rk { return lk < rk }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { (key: $0.key, target: $0.target) }
        bindings = [:]
        for pair in bindingNames {
            guard let code = Keys.code(for: pair.key) else { continue }
            // A conflicted imported profile remains editable, but dispatch is stable:
            // the first durable row wins rather than dictionary iteration choosing one.
            if bindings[code] == nil { bindings[code] = LaunchTarget(rawValue: pair.target) }
        }
    }

    mutating func ensureProfileInvariant() {
        if profiles.isEmpty {
            profiles = [ShortcutProfile(id: Self.defaultProfileID, name: "Default")]
        }
        if activeProfileID == nil || !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles[0].id
        }
    }

    @discardableResult
    mutating func createProfile(named rawName: String, copying sourceID: UUID? = nil) throws -> UUID {
        let name = try validatedProfileName(rawName)
        let source = sourceID.flatMap { id in profiles.first(where: { $0.id == id }) }
        let bindings = source?.allBindings.map {
            ShortcutBinding(key: $0.key, target: $0.target)
        } ?? []
        let profile = ShortcutProfile(name: name, bindings: bindings)
        profiles.append(profile)
        _ = activateProfile(profile.id)
        return profile.id
    }

    mutating func renameProfile(_ id: UUID, to rawName: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ShortcutProfileError.missingActiveProfile
        }
        let name = try validatedProfileName(rawName, excluding: id)
        profiles[index].name = name
    }

    @discardableResult
    mutating func deleteProfile(_ id: UUID) -> Bool {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        profiles.remove(at: index)
        if activeProfileID == id { activeProfileID = profiles[0].id }
        rebuildRuntimeBindings()
        return true
    }

    mutating func importTemplate(_ template: ShortcutProfileTemplate) -> TemplateImportResult {
        ensureProfileInvariant()
        let existing = activeProfile?.allBindings ?? []
        var occupied = Set(existing.compactMap { Keys.canonicalName(for: $0.key) })
        var targets = Set(existing.map(\.target))
        var merged = existing
        var skippedKeys: [String] = []
        var skippedTargets: [String] = []
        var imported = 0

        for candidate in template.profile.allBindings {
            let canonical = Keys.canonicalName(for: candidate.key) ?? candidate.key.lowercased()
            if occupied.contains(canonical) {
                skippedKeys.append(candidate.key)
                continue
            }
            if targets.contains(candidate.target) {
                skippedTargets.append(candidate.target)
                continue
            }
            occupied.insert(canonical)
            targets.insert(candidate.target)
            merged.append(ShortcutBinding(key: candidate.key, target: candidate.target))
            imported += 1
        }
        setProfileBindings(merged)
        return TemplateImportResult(
            importedCount: imported,
            skippedOccupiedKeys: skippedKeys.sorted(),
            skippedExistingTargets: skippedTargets.sorted()
        )
    }

    private func validatedProfileName(_ rawName: String, excluding id: UUID? = nil) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ShortcutProfileError.emptyProfileName }
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !profiles.contains(where: {
            $0.id != id && $0.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            ) == folded
        }) else {
            throw ShortcutProfileError.duplicateProfileName(name)
        }
        return name
    }

    static func == (lhs: Config, rhs: Config) -> Bool {
        lhs.enabled == rhs.enabled
            && lhs.debug == rhs.debug
            && lhs.tapActionRaw == rhs.tapActionRaw
            && lhs.tapThresholdMs == rhs.tapThresholdMs
            && lhs.tapActionHoldMs == rhs.tapActionHoldMs
            && lhs.repeatPressRaw == rhs.repeatPressRaw
            && lhs.clipboard == rhs.clipboard
            && lhs.clipboardBindingsSeeded == rhs.clipboardBindingsSeeded
            && lhs.profiles == rhs.profiles
            && lhs.activeProfileID == rhs.activeProfileID
            && lhs.bindingNames.map { [$0.key, $0.target] } == rhs.bindingNames.map { [$0.key, $0.target] }
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
    /// Versioned profile schema. `bindings` remains beside it as the active profile's
    /// downgrade mirror for releases that predate profiles.
    var activeProfileID: UUID?
    var profiles: [ShortcutProfile]?
    /// Correlates config.json with the independently durable profile sidecar. Old
    /// releases discard this unknown field, which is itself a downgrade signal.
    var profileRecoveryToken: UUID?
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
    var sensitiveHandling: String?
    var sensitiveTTLMinutes: Int?
    var pauseUntilTimestamp: TimeInterval?
    var ignoredApps: [String]?
    /// Decode as strings so one typo can be skipped without rejecting the entire
    /// configuration file and all unrelated shortcuts.
    var applicationRules: [String: String]?
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
    static var profileRecoveryURL: URL { directory.appendingPathComponent("profiles-recovery.json") }
    static var importRecoveryURL: URL { directory.appendingPathComponent("profiles-import-restore.json") }

    /// Returns nil when the file exists but cannot be parsed, so the caller can keep
    /// the bindings it already has instead of silently dropping every shortcut.
    static func load() -> Config? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.info("no config at \(url.path, privacy: .public), writing default")
            writeDefaultIfMissing()
            return decode(defaultJSON.data(using: .utf8)!)
        }
        guard let data = try? boundedData(at: url),
              let cfg = decode(data, modifiedAt: modificationDate(of: url)) else {
            log.error("config at \(url.path, privacy: .public) is not valid JSON — keeping previous bindings")
            return nil
        }
        return cfg
    }

    private static func decode(_ data: Data, modifiedAt: Date? = nil) -> Config? {
        guard data.count <= ShortcutProfileBudget.maxFileBytes else { return nil }
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
            if let raw = stored.sensitiveHandling,
               let handling = SensitiveClipboardHandling(rawValue: raw) {
                clipboard.sensitiveHandling = handling
            }
            clipboard.sensitiveTTLMinutes = min(
                max(stored.sensitiveTTLMinutes ?? clipboard.sensitiveTTLMinutes, 1), 24 * 60
            )
            if let timestamp = stored.pauseUntilTimestamp, timestamp.isFinite {
                let current = Date()
                let requested = Date(timeIntervalSince1970: timestamp)
                if requested > current {
                    clipboard.pauseUntil = min(
                        requested, current.addingTimeInterval(24 * 60 * 60)
                    )
                }
            }
            // Hand-edited files are the norm here, so drop blanks and duplicates rather
            // than letting them sit in the list where they can never match anything.
            if let ignored = stored.ignoredApps {
                var seen = Set<String>()
                clipboard.ignoredApps = ignored
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            // The richer rule wins when both new and legacy keys mention the same app.
            // This makes the legacy `ignoredApps` field a downgrade aid, not a source
            // that can overwrite an intentional textOnly/noImages choice.
            for (rawBundleID, rawRule) in stored.applicationRules ?? [:] {
                let bundleID = rawBundleID.trimmingCharacters(in: .whitespaces)
                guard !bundleID.isEmpty,
                      let rule = ClipboardApplicationRule(rawValue: rawRule) else {
                    log.error("invalid clipboard application rule skipped")
                    continue
                }
                clipboard.applicationRules[bundleID] = rule
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

        let rawLegacyBindings = file.bindings ?? [:]
        guard rawLegacyBindings.count <= ShortcutProfileBudget.maxBindingsPerProfile else {
            log.error("legacy binding section exceeds the per-profile safety budget")
            return nil
        }
        var legacyBindings: [ShortcutBinding] = []
        legacyBindings.reserveCapacity(rawLegacyBindings.count)
        var inspectedLegacyBindingCount = 0
        for (rawKey, rawTarget) in rawLegacyBindings {
            inspectedLegacyBindingCount += 1
            guard inspectedLegacyBindingCount <= ShortcutProfileBudget.maxBindingsPerProfile else {
                log.error("legacy binding section exceeds the per-profile safety budget")
                return nil
            }
            guard rawKey.utf8.count <= ShortcutProfileBudget.maxKeyBytes else {
                log.error("legacy binding key exceeds the safety length budget")
                return nil
            }
            guard rawTarget.utf8.count <= ShortcutProfileBudget.maxTargetBytes else {
                log.error("legacy binding target exceeds the safety length budget")
                return nil
            }
            guard let code = Keys.code(for: rawKey) else {
                log.error("unknown key '\(rawKey, privacy: .public)' in config — skipped")
                continue
            }
            _ = code
            legacyBindings.append(ShortcutBinding(key: rawKey, target: rawTarget))
        }

        if let storedProfiles = file.profiles, !storedProfiles.isEmpty {
            let requested = file.activeProfileID ?? storedProfiles[0].id
            let archive = ShortcutProfileArchive(activeProfileID: requested, profiles: storedProfiles)
            guard (try? archive.validate()) != nil else {
                log.error("profile section failed validation — keeping previous config")
                return nil
            }
            cfg.profiles = storedProfiles
            cfg.activeProfileID = requested
        } else if let snapshot = loadRecoverySnapshot(at: profileRecoveryURL),
                  shouldAutomaticallyRecover(
                    snapshot: snapshot,
                    file: file,
                    legacyBindings: Dictionary(
                        legacyBindings.map { ($0.key, $0.target) },
                        uniquingKeysWith: { first, _ in first }
                    ),
                    modifiedAt: modifiedAt
                  ) {
            cfg.profiles = snapshot.archive.profiles
            cfg.activeProfileID = snapshot.archive.activeProfileID
            log.info("restored \(cfg.profiles.count) profiles after legacy config save")
        } else {
            // A pre-profile config becomes a single Default profile. Its UUID is stable
            // across machines, while the binding IDs become durable on the first save.
            let defaultProfile = ShortcutProfile(
                id: Config.defaultProfileID, name: "Default", bindings: legacyBindings
            )
            let migratedArchive = ShortcutProfileArchive(
                activeProfileID: Config.defaultProfileID,
                profiles: [defaultProfile]
            )
            guard (try? migratedArchive.validate()) != nil else {
                log.error("legacy binding migration failed validation — keeping previous config")
                return nil
            }
            cfg.profiles = [defaultProfile]
            cfg.activeProfileID = Config.defaultProfileID
        }
        cfg.rebuildRuntimeBindings()
        return cfg
    }

    /// Writes atomically so a crash mid-write cannot leave a truncated file that the
    /// next launch would reject.
    @discardableResult
    static func save(_ config: Config) -> Bool {
        guard let activeProfileID = config.activeProfileID else {
            log.error("config save refused: active profile is missing")
            return false
        }
        let profileArchive = ShortcutProfileArchive(
            activeProfileID: activeProfileID, profiles: config.profiles
        )
        guard (try? profileArchive.validate()) != nil else {
            log.error("config save refused: profile model failed validation")
            return false
        }
        var bindings: [String: String] = [:]
        for pair in config.bindingNames where bindings[pair.key] == nil {
            bindings[pair.key] = pair.target
        }
        let recoveryToken = UUID()
        guard let recoverySnapshot = try? ProfileRecoverySnapshot(
            token: recoveryToken, config: config
        ) else {
            log.error("config save refused: recovery snapshot failed validation")
            return false
        }

        var clipboard: [String: Any] = [
            "enabled": config.clipboard.enabled,
            "retentionDays": config.clipboard.retentionDays,
            "maxItems": config.clipboard.maxItems,
            "maxItemMB": config.clipboard.maxItemMB,
            "recordImages": config.clipboard.recordImages,
            "skipConcealed": config.clipboard.skipConcealed,
            "skipTransient": config.clipboard.skipTransient,
            "sensitiveHandling": config.clipboard.sensitiveHandling.rawValue,
            "sensitiveTTLMinutes": config.clipboard.sensitiveTTLMinutes,
            "ignoredApps": config.clipboard.ignoredApps,
            "applicationRules": config.clipboard.applicationRules.mapValues(\.rawValue),
            "restoreAfterPaste": config.clipboard.restoreAfterPaste,
            "joinSeparator": config.clipboard.joinSeparator,
            "panelSize": config.clipboard.panelSize,
            "panelPosition": config.clipboard.panelPosition,
            "returnAction": config.clipboard.returnAction,
        ]
        if let pauseUntil = config.clipboard.pauseUntil {
            clipboard["pauseUntilTimestamp"] = pauseUntil.timeIntervalSince1970
        }

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
            "activeProfileID": config.activeProfileID?.uuidString ?? "",
            "profiles": profilesJSONObject(config.profiles),
            "profileRecoveryToken": recoveryToken.uuidString,
        ]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: document, options: [.prettyPrinted, .sortedKeys]
            )
            guard data.count <= ShortcutProfileBudget.maxFileBytes else {
                throw ShortcutProfileError.fileTooLarge
            }
            // Write the sidecar first. If config.json then fails, its intact profile
            // section still wins on load; if an old release later overwrites it, the
            // sidecar is already durable and can restore every non-active Profile.
            try writeRecoverySnapshot(recoverySnapshot, to: profileRecoveryURL)
            try data.write(to: url, options: .atomic)
            log.info("config saved: \(bindings.count) bindings")
            return true
        } catch {
            log.error("config save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Export is deliberately only the profile domain: importing shortcuts must never
    /// overwrite privacy, retention, launch-at-login, or clipboard storage settings.
    static func exportProfiles(_ config: Config) throws -> Data {
        guard let activeProfileID = config.activeProfileID else {
            throw ShortcutProfileError.missingActiveProfile
        }
        let archive = ShortcutProfileArchive(
            activeProfileID: activeProfileID, profiles: config.profiles
        )
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= ShortcutProfileBudget.maxFileBytes else {
            throw ShortcutProfileError.fileTooLarge
        }
        return data
    }

    /// Validates into a temporary value before touching the caller's config. The return
    /// value can then be atomically persisted and applied by AppDelegate.
    static func importProfiles(_ data: Data, into config: Config) throws -> Config {
        guard data.count <= ShortcutProfileBudget.maxFileBytes else {
            throw ShortcutProfileError.fileTooLarge
        }
        let archive = try JSONDecoder().decode(ShortcutProfileArchive.self, from: data)
        try archive.validate()
        var candidate = config
        candidate.profiles = archive.profiles
        candidate.activeProfileID = archive.activeProfileID
        candidate.rebuildRuntimeBindings()
        return candidate
    }

    /// Checks the filesystem allocation before reading. The post-read count check closes
    /// the race where a file grows between stat and Data(contentsOf:).
    static func readProfileArchive(at sourceURL: URL) throws -> Data {
        try boundedData(at: sourceURL)
    }

    @discardableResult
    static func saveImportRecovery(_ config: Config) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = try ProfileRecoverySnapshot(config: config)
            try writeRecoverySnapshot(snapshot, to: importRecoveryURL)
            return true
        } catch {
            log.error("import recovery save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func loadImportRecovery(into config: Config) throws -> Config {
        guard let snapshot = loadRecoverySnapshot(at: importRecoveryURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var restored = config
        restored.profiles = snapshot.archive.profiles
        restored.activeProfileID = snapshot.archive.activeProfileID
        restored.rebuildRuntimeBindings()
        return restored
    }

    static func loadDowngradeRecovery(into config: Config) throws -> Config {
        guard let snapshot = loadRecoverySnapshot(at: profileRecoveryURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var restored = config
        restored.profiles = snapshot.archive.profiles
        restored.activeProfileID = snapshot.archive.activeProfileID
        restored.rebuildRuntimeBindings()
        return restored
    }

    static var hasImportRecovery: Bool {
        loadRecoverySnapshot(at: importRecoveryURL) != nil
    }

    static var hasDowngradeRecovery: Bool {
        guard let data = try? boundedData(at: url),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data),
              file.profiles?.isEmpty != false,
              let snapshot = loadRecoverySnapshot(at: profileRecoveryURL) else { return false }
        let legacyBindings = file.bindings ?? [:]
        return !shouldAutomaticallyRecover(
            snapshot: snapshot,
            file: file,
            legacyBindings: legacyBindings,
            modifiedAt: modificationDate(of: url)
        )
    }

    static func clearImportRecovery() {
        try? FileManager.default.removeItem(at: importRecoveryURL)
    }

    private static func boundedData(at sourceURL: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= ShortcutProfileBudget.maxFileBytes else {
            throw ShortcutProfileError.fileTooLarge
        }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard data.count <= ShortcutProfileBudget.maxFileBytes else {
            throw ShortcutProfileError.fileTooLarge
        }
        return data
    }

    private static func writeRecoverySnapshot(
        _ snapshot: ProfileRecoverySnapshot, to destination: URL
    ) throws {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= ShortcutProfileBudget.maxFileBytes else {
            throw ShortcutProfileError.fileTooLarge
        }
        try data.write(to: destination, options: .atomic)
    }

    private static func loadRecoverySnapshot(at sourceURL: URL) -> ProfileRecoverySnapshot? {
        guard let data = try? boundedData(at: sourceURL),
              let snapshot = try? JSONDecoder().decode(ProfileRecoverySnapshot.self, from: data),
              (try? snapshot.validate()) != nil else { return nil }
        return snapshot
    }

    private static func shouldAutomaticallyRecover(
        snapshot: ProfileRecoverySnapshot,
        file: ConfigFile,
        legacyBindings: [String: String],
        modifiedAt: Date?
    ) -> Bool {
        if file.profileRecoveryToken == snapshot.token { return true }
        guard legacyBindings == snapshot.legacyBindings,
              legacyBindings != shippedDefaultLegacyBindings,
              let modifiedAt,
              modifiedAt >= snapshot.createdAt.addingTimeInterval(-2),
              modifiedAt.timeIntervalSince(snapshot.createdAt) <= 180 * 24 * 3600 else {
            return false
        }
        return true
    }

    private static var shippedDefaultLegacyBindings: [String: String] {
        guard let data = defaultJSON.data(using: .utf8),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return [:] }
        return file.bindings ?? [:]
    }

    private static func modificationDate(of sourceURL: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        return attributes?[.modificationDate] as? Date
    }

    private static func profilesJSONObject(_ profiles: [ShortcutProfile]) -> [[String: Any]] {
        profiles.map { profile in
            [
                "id": profile.id.uuidString,
                "name": profile.name,
                "applicationBindings": bindingsJSONObject(profile.applicationBindings),
                "clipboardActionBindings": bindingsJSONObject(profile.clipboardActionBindings),
            ]
        }
    }

    private static func bindingsJSONObject(_ bindings: [ShortcutBinding]) -> [[String: Any]] {
        bindings.map { binding in
            ["id": binding.id.uuidString, "key": binding.key, "target": binding.target]
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
        "sensitiveHandling": "expire",
        "sensitiveTTLMinutes": 5,
        "ignoredApps": [],
        "applicationRules": {},
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
