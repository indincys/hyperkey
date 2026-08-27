import Foundation

enum ShortcutProfileBudget {
    /// Shared by startup config loading, profile import, and recovery sidecars.
    static let maxFileBytes = 4 * 1024 * 1024
    static let maxProfiles = 64
    static let maxBindingsPerProfile = 256
    static let maxTotalBindings = 4096
    static let maxProfileNameBytes = 128
    static let maxKeyBytes = 32
    static let maxTargetBytes = 2048
}

/// One durable shortcut entry. The UUID is persisted so conflict messages and
/// accessibility focus continue to point at the same row after reload/import.
struct ShortcutBinding: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var key: String
    var target: String

    init(id: UUID = UUID(), key: String, target: String) {
        self.id = id
        self.key = key
        self.target = target
    }
}

/// A complete shortcut context. Application launchers and Hyper-owned clipboard
/// actions are intentionally stored separately in JSON: exports remain legible and a
/// malformed `@action` can be explained precisely instead of looking like a missing app.
struct ShortcutProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var applicationBindings: [ShortcutBinding]
    var clipboardActionBindings: [ShortcutBinding]

    init(
        id: UUID = UUID(),
        name: String,
        applicationBindings: [ShortcutBinding] = [],
        clipboardActionBindings: [ShortcutBinding] = []
    ) {
        self.id = id
        self.name = name
        self.applicationBindings = applicationBindings
        self.clipboardActionBindings = clipboardActionBindings
    }

    init(id: UUID = UUID(), name: String, bindings: [ShortcutBinding]) {
        self.id = id
        self.name = name
        self.applicationBindings = bindings.filter { !$0.target.hasPrefix("@") }
        self.clipboardActionBindings = bindings.filter { $0.target.hasPrefix("@") }
    }

    var allBindings: [ShortcutBinding] {
        applicationBindings + clipboardActionBindings
    }

    mutating func replaceBindings(_ bindings: [ShortcutBinding]) {
        applicationBindings = bindings.filter { !$0.target.hasPrefix("@") }
        clipboardActionBindings = bindings.filter { $0.target.hasPrefix("@") }
    }
}

enum ShortcutProfileError: LocalizedError, Equatable {
    case fileTooLarge
    case unsupportedSchema(Int)
    case noProfiles
    case missingActiveProfile
    case duplicateProfileID
    case duplicateProfileName(String)
    case duplicateBindingID
    case emptyProfileName
    case emptyKey
    case emptyTarget
    case invalidKey(String)
    case tooManyProfiles
    case tooManyBindingsInProfile(String)
    case tooManyBindings
    case stringTooLong(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "文件超过 4 MB 安全上限"
        case .unsupportedSchema(let version): return "不支持的快捷键配置版本（\(version)）"
        case .noProfiles: return "导入文件里没有任何 Profile"
        case .missingActiveProfile: return "当前 Profile 不在导入列表中"
        case .duplicateProfileID: return "导入文件包含重复的 Profile ID"
        case .duplicateProfileName(let name): return "Profile 名称重复：\(name)"
        case .duplicateBindingID: return "导入文件包含重复的快捷键条目 ID"
        case .emptyProfileName: return "Profile 名称不能为空"
        case .emptyKey: return "快捷键不能为空"
        case .emptyTarget: return "快捷键目标不能为空"
        case .invalidKey(let key): return "无法识别快捷键：\(key)"
        case .tooManyProfiles: return "Profile 数量超过安全上限（\(ShortcutProfileBudget.maxProfiles)）"
        case .tooManyBindingsInProfile(let name):
            return "Profile“\(name)”的快捷键超过安全上限（\(ShortcutProfileBudget.maxBindingsPerProfile)）"
        case .tooManyBindings:
            return "快捷键总数超过安全上限（\(ShortcutProfileBudget.maxTotalBindings)）"
        case .stringTooLong(let field): return "\(field)超过安全长度上限"
        }
    }
}

struct ShortcutProfileArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var activeProfileID: UUID
    var profiles: [ShortcutProfile]

    init(activeProfileID: UUID, profiles: [ShortcutProfile]) {
        schemaVersion = Self.currentSchemaVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ShortcutProfileError.unsupportedSchema(schemaVersion)
        }
        guard !profiles.isEmpty else { throw ShortcutProfileError.noProfiles }
        guard profiles.count <= ShortcutProfileBudget.maxProfiles else {
            throw ShortcutProfileError.tooManyProfiles
        }
        guard profiles.contains(where: { $0.id == activeProfileID }) else {
            throw ShortcutProfileError.missingActiveProfile
        }

        var profileIDs = Set<UUID>()
        var profileNames = Set<String>()
        var bindingIDs = Set<UUID>()
        var totalBindings = 0
        for profile in profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw ShortcutProfileError.duplicateProfileID
            }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ShortcutProfileError.emptyProfileName }
            guard name.utf8.count <= ShortcutProfileBudget.maxProfileNameBytes else {
                throw ShortcutProfileError.stringTooLong("Profile name")
            }
            let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard profileNames.insert(folded).inserted else {
                throw ShortcutProfileError.duplicateProfileName(name)
            }
            let bindings = profile.allBindings
            guard bindings.count <= ShortcutProfileBudget.maxBindingsPerProfile else {
                throw ShortcutProfileError.tooManyBindingsInProfile(name)
            }
            totalBindings += bindings.count
            guard totalBindings <= ShortcutProfileBudget.maxTotalBindings else {
                throw ShortcutProfileError.tooManyBindings
            }
            for binding in bindings {
                guard bindingIDs.insert(binding.id).inserted else {
                    throw ShortcutProfileError.duplicateBindingID
                }
                let key = binding.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw ShortcutProfileError.emptyKey }
                guard key.utf8.count <= ShortcutProfileBudget.maxKeyBytes else {
                    throw ShortcutProfileError.stringTooLong("Key")
                }
                guard Keys.code(for: key) != nil else { throw ShortcutProfileError.invalidKey(key) }
                let target = binding.target.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else {
                    throw ShortcutProfileError.emptyTarget
                }
                guard target.utf8.count <= ShortcutProfileBudget.maxTargetBytes else {
                    throw ShortcutProfileError.stringTooLong("Target")
                }
            }
        }
    }
}

struct ProfileRecoverySnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var token: UUID
    var createdAt: Date
    var legacyBindings: [String: String]
    var archive: ShortcutProfileArchive

    init(token: UUID = UUID(), config: Config, createdAt: Date = Date()) throws {
        guard let activeProfileID = config.activeProfileID else {
            throw ShortcutProfileError.missingActiveProfile
        }
        self.token = token
        self.createdAt = createdAt
        self.legacyBindings = Dictionary(
            config.bindingNames.map { ($0.key, $0.target) }, uniquingKeysWith: { first, _ in first }
        )
        self.archive = ShortcutProfileArchive(
            activeProfileID: activeProfileID, profiles: config.profiles
        )
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ShortcutProfileError.unsupportedSchema(schemaVersion)
        }
        try archive.validate()
        guard legacyBindings.count <= ShortcutProfileBudget.maxBindingsPerProfile else {
            throw ShortcutProfileError.tooManyBindings
        }
        for (key, target) in legacyBindings {
            guard key.utf8.count <= ShortcutProfileBudget.maxKeyBytes else {
                throw ShortcutProfileError.stringTooLong("Key")
            }
            guard target.utf8.count <= ShortcutProfileBudget.maxTargetBytes else {
                throw ShortcutProfileError.stringTooLong("Target")
            }
        }
    }
}

enum ShortcutConflictKind: String, Codable, Equatable {
    case duplicateKey
    case systemReservedKey
    case duplicateBuiltinAction
    case unknownBuiltinAction
    case missingApplication

    fileprivate var rank: Int {
        switch self {
        case .duplicateKey: return 0
        case .systemReservedKey: return 1
        case .duplicateBuiltinAction: return 2
        case .unknownBuiltinAction: return 3
        case .missingApplication: return 4
        }
    }
}

struct ShortcutConflict: Equatable, Identifiable {
    let kind: ShortcutConflictKind
    let bindingIDs: [UUID]
    let explanation: String

    var id: String {
        "\(kind.rawValue):" + bindingIDs.map(\.uuidString).joined(separator: ",")
    }
}

enum ShortcutConflictEngine {
    /// Pure conflict analysis. Target resolution is injected so tests are deterministic
    /// and the settings UI can use LaunchServices without coupling it to this model.
    static func evaluate(
        profile: ShortcutProfile,
        targetExists: (String) -> Bool
    ) -> [ShortcutConflict] {
        let all = profile.allBindings
        var conflicts: [ShortcutConflict] = []

        let keyGroups = Dictionary(grouping: all) { binding in
            Keys.canonicalName(for: binding.key) ?? binding.key.lowercased()
        }
        for key in keyGroups.keys.sorted() {
            guard let group = keyGroups[key], group.count > 1 else { continue }
            conflicts.append(ShortcutConflict(
                kind: .duplicateKey,
                bindingIDs: group.map(\.id).sorted { $0.uuidString < $1.uuidString },
                explanation: "⇪ + \(Keys.display(forName: key)) 在当前 Profile 中重复；一次按键只能执行一个目标。"
            ))
        }

        for binding in all.sorted(by: stableBindingOrder) {
            if let reason = Keys.systemReservationReason(for: binding.key) {
                conflicts.append(ShortcutConflict(
                    kind: .systemReservedKey,
                    bindingIDs: [binding.id],
                    explanation: reason
                ))
            }
        }

        let actionGroups = Dictionary(grouping: profile.clipboardActionBindings) { $0.target }
        for target in actionGroups.keys.sorted() {
            guard BuiltinAction(rawValue: target) != nil,
                  let group = actionGroups[target], group.count > 1 else { continue }
            let name = BuiltinAction(rawValue: target)?.displayName ?? target
            conflicts.append(ShortcutConflict(
                kind: .duplicateBuiltinAction,
                bindingIDs: group.map(\.id).sorted { $0.uuidString < $1.uuidString },
                explanation: "Hyper 动作“\(name)”绑定了多次；保留一个即可避免重复入口。"
            ))
        }

        for binding in profile.clipboardActionBindings.sorted(by: stableBindingOrder) {
            guard BuiltinAction(rawValue: binding.target) == nil else { continue }
            conflicts.append(ShortcutConflict(
                kind: .unknownBuiltinAction,
                bindingIDs: [binding.id],
                explanation: "“\(binding.target)”不是当前版本支持的 Hyper 内建动作。"
            ))
        }
        for binding in profile.applicationBindings.sorted(by: stableBindingOrder) {
            if binding.target.hasPrefix("@") {
                conflicts.append(ShortcutConflict(
                    kind: .unknownBuiltinAction,
                    bindingIDs: [binding.id],
                    explanation: "“\(binding.target)”被放在应用绑定中，无法安全执行。"
                ))
            } else if !targetExists(binding.target) {
                conflicts.append(ShortcutConflict(
                    kind: .missingApplication,
                    bindingIDs: [binding.id],
                    explanation: "找不到目标应用“\(binding.target)”；重新安装应用或移除此条。"
                ))
            }
        }

        return conflicts.sorted {
            if $0.kind.rank != $1.kind.rank { return $0.kind.rank < $1.kind.rank }
            if $0.explanation != $1.explanation { return $0.explanation < $1.explanation }
            return $0.id < $1.id
        }
    }

    private static func stableBindingOrder(_ lhs: ShortcutBinding, _ rhs: ShortcutBinding) -> Bool {
        let lk = Keys.canonicalName(for: lhs.key) ?? lhs.key.lowercased()
        let rk = Keys.canonicalName(for: rhs.key) ?? rhs.key.lowercased()
        if lk != rk { return lk < rk }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ShortcutProfileTemplate: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let symbolName: String
    let profile: ShortcutProfile

    static let builtIns: [ShortcutProfileTemplate] = [
        ShortcutProfileTemplate(
            id: "work",
            name: "Work",
            summary: "浏览器、终端、开发工具和剪贴板流水线",
            symbolName: "briefcase",
            profile: ShortcutProfile(name: "Work", bindings: [
                ShortcutBinding(key: "c", target: "com.google.Chrome"),
                ShortcutBinding(key: "f", target: "com.apple.finder"),
                ShortcutBinding(key: "t", target: "com.mitchellh.ghostty"),
                ShortcutBinding(key: "x", target: "com.apple.dt.Xcode"),
                ShortcutBinding(key: "space", target: BuiltinAction.clipboardPanel.rawValue),
                ShortcutBinding(key: "q", target: BuiltinAction.clipEnqueue.rawValue),
                ShortcutBinding(key: "v", target: BuiltinAction.clipPasteNext.rawValue),
            ])
        ),
        ShortcutProfileTemplate(
            id: "communication",
            name: "Communication",
            summary: "沟通、邮件、日程和连续复制粘贴",
            symbolName: "bubble.left.and.bubble.right",
            profile: ShortcutProfile(name: "Communication", bindings: [
                ShortcutBinding(key: "l", target: "com.electron.lark"),
                ShortcutBinding(key: "m", target: "com.apple.MobileSMS"),
                ShortcutBinding(key: "w", target: "com.tencent.xinWeChat"),
                ShortcutBinding(key: "e", target: "com.apple.mail"),
                ShortcutBinding(key: "space", target: BuiltinAction.clipboardPanel.rawValue),
                ShortcutBinding(key: "q", target: BuiltinAction.clipEnqueue.rawValue),
                ShortcutBinding(key: "v", target: BuiltinAction.clipPasteNext.rawValue),
            ])
        ),
        ShortcutProfileTemplate(
            id: "creator",
            name: "Creator",
            summary: "素材整理、预览、演示与高频内容复用",
            symbolName: "paintbrush",
            profile: ShortcutProfile(name: "Creator", bindings: [
                ShortcutBinding(key: "f", target: "com.apple.finder"),
                ShortcutBinding(key: "k", target: "com.apple.Keynote"),
                ShortcutBinding(key: "p", target: "com.apple.Preview"),
                ShortcutBinding(key: "s", target: "com.apple.Safari"),
                ShortcutBinding(key: "space", target: BuiltinAction.clipboardPanel.rawValue),
                ShortcutBinding(key: "q", target: BuiltinAction.clipEnqueue.rawValue),
                ShortcutBinding(key: "v", target: BuiltinAction.clipPasteNext.rawValue),
            ])
        ),
    ]
}

struct TemplateImportResult: Equatable {
    let importedCount: Int
    let skippedOccupiedKeys: [String]
    let skippedExistingTargets: [String]
}
