import Cocoa
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct BindingRow: Identifiable, Equatable {
    let id: UUID
    var key: String
    /// Bundle identifier, an absolute path for applications outside the usual folders,
    /// or an `@`-prefixed built-in action.
    var target: String
    var displayName: String
    var subtitle: String
    var icon: NSImage?
    var missing: Bool
    /// Set when this row is one of the app's own actions rather than an application.
    var action: BuiltinAction?

    static func == (lhs: BindingRow, rhs: BindingRow) -> Bool {
        lhs.id == rhs.id && lhs.key == rhs.key && lhs.target == rhs.target
            && lhs.missing == rhs.missing
    }
}

/// One excluded application, already resolved for display.
///
/// The name and icon come from a LaunchServices lookup, which is far too expensive to
/// repeat per redraw — so the rows are built once when the list changes and the view
/// only ever reads them.
struct IgnoredAppRow: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let icon: NSImage?
    /// Nothing installed answers to this identifier — an uninstalled app, or a typo in
    /// a hand-edited config. Kept in the list either way: it costs nothing and the app
    /// may well come back.
    var missing: Bool { icon == nil }

    static func == (lhs: IgnoredAppRow, rhs: IgnoredAppRow) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.displayName == rhs.displayName
    }
}

struct ProfileImportPreview: Identifiable, Equatable {
    let id = UUID()
    let baselineProfiles: [ShortcutProfile]
    let baselineActiveProfileID: UUID?
    let profiles: [ShortcutProfile]
    let activeProfileID: UUID
    let currentProfileCount: Int
    let currentBindingCount: Int
    let incomingBindingCount: Int
    let addedNames: [String]
    let removedNames: [String]
    let changedNames: [String]

    static func make(current: Config, candidate: Config) -> ProfileImportPreview? {
        guard let activeProfileID = candidate.activeProfileID else { return nil }
        let currentByID = Dictionary(uniqueKeysWithValues: current.profiles.map { ($0.id, $0) })
        let incomingByID = Dictionary(uniqueKeysWithValues: candidate.profiles.map { ($0.id, $0) })
        let added = candidate.profiles.filter { currentByID[$0.id] == nil }.map(\.name).sorted()
        let removed = current.profiles.filter { incomingByID[$0.id] == nil }.map(\.name).sorted()
        let changed = candidate.profiles.compactMap { profile -> String? in
            guard let existing = currentByID[profile.id], existing != profile else { return nil }
            return profile.name
        }.sorted()
        return ProfileImportPreview(
            baselineProfiles: current.profiles,
            baselineActiveProfileID: current.activeProfileID,
            profiles: candidate.profiles,
            activeProfileID: activeProfileID,
            currentProfileCount: current.profiles.count,
            currentBindingCount: current.profiles.reduce(0) { $0 + $1.allBindings.count },
            incomingBindingCount: candidate.profiles.reduce(0) { $0 + $1.allBindings.count },
            addedNames: added,
            removedNames: removed,
            changedNames: changed
        )
    }
}

/// Backing store for the settings window. Every mutation writes the file, so there is
/// no "unsaved" state that can drift from what the tap is actually using.
final class SettingsModel: ObservableObject {
    @Published private(set) var rows: [BindingRow] = []
    /// Precomputed so the list body stays O(n) instead of rescanning per row.
    @Published private(set) var duplicateKeys: Set<String> = []
    @Published private(set) var profiles: [ShortcutProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var shortcutConflicts: [ShortcutConflict] = []
    @Published private(set) var profileNotice: String?
    @Published private(set) var pendingProfileImport: ProfileImportPreview?
    @Published private(set) var isImportingProfiles = false
    @Published private(set) var hasImportRecovery = false
    @Published private(set) var hasDowngradeRecovery = false

    @Published var enabled = true
    @Published var repeatPressRaw = RepeatPress.hide.rawValue
    @Published var debug = false
    @Published var tapActionRaw = "none"
    @Published var tapThresholdMs = 200
    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityGranted = true
    @Published private(set) var tapRunning = false
    @Published private(set) var updateStatus: String?
    @Published private(set) var inApplicationsFolder = true

    /// Seconds left in the "Caps Lock is temporarily F18" window, 0 when closed.
    @Published private(set) var recordingSecondsLeft = 0
    private var recordingTimer: Timer?

    @Published var isPickingApp = false
    @Published private(set) var catalog: [InstalledApp] = []

    // Clipboard
    @Published var clipboardEnabled = true
    @Published var retentionDays = 30
    @Published var maxItems = 1000
    @Published var maxItemMB = 20
    @Published var recordImages = true
    @Published var skipConcealed = true
    @Published var skipTransient = true
    @Published var sensitiveHandling = SensitiveClipboardHandling.expire
    @Published var sensitiveTTLMinutes = 5
    @Published private(set) var clipboardPauseUntil: Date?
    @Published var customClipboardPauseMinutes = 30
    /// Full capture-rule model. The current screen edits `.ignore`; keeping all three
    /// policies here prevents a settings save from discarding textOnly/noImages rules
    /// that came from the config file or a future UI.
    @Published private(set) var applicationRules: [String: ClipboardApplicationRule] = [:]
    @Published private(set) var ignoredApps: [String] = []
    @Published private(set) var ignoredAppRows: [IgnoredAppRow] = []
    @Published var isPickingIgnoredApp = false
    @Published var restoreAfterPaste = false
    @Published var joinSeparator = "\n"
    @Published var panelSize = ClipPanelSize.standard.rawValue
    @Published var panelPosition = ClipPanelPosition.center.rawValue
    @Published var panelAppearance = ClipPanelAppearance.system.rawValue
    @Published var returnAction = ClipReturnAction.paste.rawValue
    @Published private(set) var stats = ClipStore.Statistics()
    /// True for a couple of seconds after a cleanup, so the button can say it did
    /// something — deleting nothing looks exactly like deleting a hundred files.
    @Published private(set) var didCleanOrphans = false

    var clipboardCount: Int { stats.total }
    var pinnedCount: Int { stats.pinned }
    var diskUsage: String { Self.formatBytes(stats.diskBytes) }
    var payloadUsage: String { Self.formatBytes(stats.payloadBytes) }
    var thumbnailUsage: String { Self.formatBytes(stats.thumbnailBytes) }
    var searchUsage: String { Self.formatBytes(stats.searchBytes) }

    /// The kinds actually present, biggest slice first, so the bar and its legend read
    /// in the same order.
    var kindBreakdown: [(kind: ClipKind, count: Int)] {
        ClipKind.allCases
            .compactMap { kind in
                guard let count = stats.counts[kind], count > 0 else { return nil }
                return (kind: kind, count: count)
            }
            .sorted { $0.count > $1.count }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private weak var delegate: AppDelegate?
    private var loading = false

    init(delegate: AppDelegate?) {
        self.delegate = delegate
        reload()
    }

    // MARK: - Load / save

    func reload() {
        guard let config = delegate?.currentConfig else { return }
        loading = true
        defer { loading = false }

        enabled = config.enabled
        repeatPressRaw = config.repeatPressRaw
        debug = config.debug
        tapActionRaw = config.tapActionRaw
        tapThresholdMs = config.tapThresholdMs
        launchAtLogin = SMAppService.mainApp.status == .enabled

        clipboardEnabled = config.clipboard.enabled
        retentionDays = config.clipboard.retentionDays
        maxItems = config.clipboard.maxItems
        maxItemMB = config.clipboard.maxItemMB
        recordImages = config.clipboard.recordImages
        skipConcealed = config.clipboard.skipConcealed
        skipTransient = config.clipboard.skipTransient
        sensitiveHandling = config.clipboard.sensitiveHandling
        sensitiveTTLMinutes = config.clipboard.sensitiveTTLMinutes
        clipboardPauseUntil = config.clipboard.pauseUntil
        applicationRules = config.clipboard.applicationRules
        ignoredApps = config.clipboard.ignoredApps
        rebuildIgnoredAppRows()
        restoreAfterPaste = config.clipboard.restoreAfterPaste
        joinSeparator = config.clipboard.joinSeparator
        panelSize = config.clipboard.panelSize
        panelPosition = config.clipboard.panelPosition
        panelAppearance = config.clipboard.panelAppearance
        returnAction = config.clipboard.returnAction

        profiles = config.profiles
        activeProfileID = config.activeProfileID

        // The file stores bindings sorted by key; the list shows them by application
        // name. Sorting here keeps the order stable when the file changes underneath us.
        rows = (config.activeProfile?.allBindings ?? []).map {
            makeRow(id: $0.id, key: $0.key, target: $0.target)
        }
        sortRows()
        recomputeConflicts()
        refreshProfileRecoveryState()
        refreshClipboardStats()
        refreshStatus()
    }

    // MARK: - Clipboard

    /// The index is read from disk after launch, and this window opens itself on a first
    /// run or a reset permission — right inside that gap. Reading `records` directly
    /// would show "0 条" and never correct itself, which is a lie that invites the user
    /// to press 清空.
    func refreshClipboardStats() {
        let store = ClipboardManager.shared.store
        store.whenLoaded {
            store.statistics { [weak self] stats in self?.stats = stats }
        }
    }

    /// Deletes payload, thumbnail and search files no record points at any more.
    ///
    /// `reconcileOrphans` deletes on the store's serial file queue and the refresh
    /// measures on that same queue, so the numbers that come back are already the
    /// post-cleanup ones — no polling, no guessing at a delay.
    func cleanOrphanFiles() {
        ClipboardManager.shared.store.reconcileOrphans()
        refreshClipboardStats()
        didCleanOrphans = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.didCleanOrphans = false
        }
    }

    // MARK: - Ignored applications

    /// The catalog minus anything the capture filter could never match.
    ///
    /// `AppCatalog` falls back to a path for bundles without an identifier, and the
    /// filter compares against `frontmostApplication.bundleIdentifier` — so offering
    /// those entries would only ever produce a rule that silently does nothing.
    var ignorableCatalog: [InstalledApp] {
        catalog.filter { !$0.target.hasPrefix("/") }
    }

    var ignoredAppIDs: Set<String> { Set(ignoredApps) }

    func addIgnoredApp(_ bundleID: String) {
        setApplicationRule(.ignore, for: bundleID)
    }

    func removeIgnoredApp(_ bundleID: String) {
        guard applicationRules[bundleID] == .ignore else { return }
        applicationRules[bundleID] = nil
        syncIgnoredAppsFromRules()
        save()
    }

    /// Model API for the richer settings UI that will follow this privacy foundation.
    /// It is deliberately usable now by tests and config-driven installs.
    func setApplicationRule(_ rule: ClipboardApplicationRule, for bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, applicationRules[id] != rule else { return }
        applicationRules[id] = rule
        syncIgnoredAppsFromRules()
        save()
    }

    func removeApplicationRule(for bundleID: String) {
        guard applicationRules.removeValue(forKey: bundleID) != nil else { return }
        syncIgnoredAppsFromRules()
        save()
    }

    private func syncIgnoredAppsFromRules() {
        ignoredApps = applicationRules.compactMap { $0.value == .ignore ? $0.key : nil }.sorted()
        rebuildIgnoredAppRows()
    }

    /// Fallback for applications outside the folders the catalog scans.
    func addIgnoredAppFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        panel.message = "选择不记录剪贴板的应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            let alert = NSAlert()
            alert.messageText = "这个应用没有 bundle identifier"
            alert.informativeText = "无法识别复制来源，所以没办法忽略它。"
            alert.runModal()
            return
        }
        addIgnoredApp(bundleID)
    }

    private func rebuildIgnoredAppRows() {
        ignoredAppRows = ignoredApps.map { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return IgnoredAppRow(bundleID: bundleID, displayName: bundleID, icon: nil)
            }
            // Shared with the clipboard panel, and deliberately not resized: the cache
            // holds one instance per application, so setting `size` here would shrink
            // the image every other view draws — which is how the panel's 27pt icons
            // ended up blurry after a visit to this window. The row asks for 16pt
            // through `.resizable().frame(…)` instead.
            return IgnoredAppRow(
                bundleID: bundleID,
                displayName: url.deletingPathExtension().lastPathComponent,
                icon: AppIconCache.shared.appIcon(bundleID: bundleID)
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Actions with no key bound to them yet, so the settings screen can offer to add
    /// the ones an upgrade had to skip.
    var unboundActions: [BuiltinAction] {
        let bound = Set(rows.compactMap(\.action))
        return BuiltinAction.allCases.filter { !bound.contains($0) }
    }

    func addAction(_ action: BuiltinAction) {
        guard !rows.contains(where: { $0.action == action }) else { return }
        let preferred = Config.clipboardDefaultKeys.first { $0.action == action }?.key
        let taken = Set(rows.map(\.key))
        let key = (preferred.map { taken.contains($0) ? nil : $0 } ?? nil)
            ?? suggestKey(for: action.displayName)
        rows.append(makeRow(key: key, target: action.rawValue))
        sortRows()
        save()
    }

    func clearClipboardHistory(includingPinned: Bool) {
        let alert = NSAlert()
        alert.messageText = includingPinned ? "清空全部剪贴板历史？" : "清空剪贴板历史？"
        alert.informativeText = includingPinned
            ? "包括收藏的内容在内，全部删除。这个操作无法撤销。"
            : "收藏的 \(pinnedCount) 条会保留下来。这个操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClipboardManager.shared.clearHistory(includingPinned: includingPinned)
        refreshClipboardStats()
    }

    func revealClipboardFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ClipStore.directory.path)
    }

    var activeClipboardPauseUntil: Date? {
        guard let clipboardPauseUntil, clipboardPauseUntil > Date() else { return nil }
        return clipboardPauseUntil
    }

    func pauseClipboard(minutes: Int) {
        let bounded = min(max(minutes, 1), 24 * 60)
        clipboardPauseUntil = Date().addingTimeInterval(TimeInterval(bounded * 60))
        save()
    }

    func resumeClipboardCapture() {
        clipboardPauseUntil = nil
        save()
    }

    /// Cheap, and called from the places that already know something changed.
    func refreshStatus() {
        accessibilityGranted = Permissions.isTrusted
        tapRunning = HyperTap.shared.isRunning
        updateStatus = delegate?.updateStatus
        inApplicationsFolder = InstallLocation.isInApplicationsFolder
    }

    func checkForUpdates() {
        delegate?.checkForUpdates(userInitiated: true)
    }

    var version: String { Hyper.version }

    func save() {
        guard !loading, let delegate else { return }
        var config = delegate.currentConfig
        config.enabled = enabled
        config.repeatPressRaw = repeatPressRaw
        config.debug = debug
        config.tapActionRaw = tapActionRaw
        config.tapAction = TapAction(rawValue: tapActionRaw)
        config.tapThresholdMs = tapThresholdMs
        var clipboard = ClipboardSettings()
        clipboard.enabled = clipboardEnabled
        clipboard.retentionDays = retentionDays
        clipboard.maxItems = maxItems
        clipboard.maxItemMB = maxItemMB
        clipboard.recordImages = recordImages
        clipboard.skipConcealed = skipConcealed
        clipboard.skipTransient = skipTransient
        clipboard.sensitiveHandling = sensitiveHandling
        clipboard.sensitiveTTLMinutes = sensitiveTTLMinutes
        clipboard.pauseUntil = clipboardPauseUntil
        clipboard.applicationRules = applicationRules
        clipboard.restoreAfterPaste = restoreAfterPaste
        clipboard.joinSeparator = joinSeparator
        clipboard.panelSize = panelSize
        clipboard.panelPosition = panelPosition
        clipboard.panelAppearance = panelAppearance
        clipboard.returnAction = returnAction
        config.clipboard = clipboard
        config.setProfileBindings(rows.map {
            ShortcutBinding(id: $0.id, key: $0.key, target: $0.target)
        })
        guard delegate.saveConfig(config) else {
            profileNotice = "配置写入失败，已恢复上一次生效的设置"
            reload()
            return
        }
        profiles = config.profiles
        activeProfileID = config.activeProfileID
        recomputeConflicts()
    }

    private func recomputeConflicts() {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for row in rows {
            let key = Keys.canonicalName(for: row.key) ?? row.key.lowercased()
            if !seen.insert(key).inserted { duplicates.insert(key) }
        }
        duplicateKeys = duplicates
        guard let profile = currentRowsProfile() else {
            shortcutConflicts = []
            return
        }
        shortcutConflicts = ShortcutConflictEngine.evaluate(profile: profile) { target in
            let isPath = target.hasPrefix("/") || target.hasPrefix("~") || target.hasSuffix(".app")
            if isPath {
                return FileManager.default.fileExists(
                    atPath: (target as NSString).expandingTildeInPath
                )
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) != nil
        }
    }

    private func currentRowsProfile() -> ShortcutProfile? {
        guard let activeProfileID,
              let name = profiles.first(where: { $0.id == activeProfileID })?.name else { return nil }
        return ShortcutProfile(
            id: activeProfileID,
            name: name,
            bindings: rows.map { ShortcutBinding(id: $0.id, key: $0.key, target: $0.target) }
        )
    }

    var activeProfileName: String {
        profiles.first(where: { $0.id == activeProfileID })?.name ?? "Default"
    }

    func conflicts(for row: BindingRow) -> [ShortcutConflict] {
        shortcutConflicts.filter { $0.bindingIDs.contains(row.id) }
    }

    // MARK: - Profiles

    func switchProfile(to id: UUID) {
        guard id != activeProfileID, let delegate else { return }
        var candidate = delegate.currentConfig
        guard candidate.activateProfile(id), delegate.saveConfig(candidate) else {
            profileNotice = "切换失败，仍在使用 \(activeProfileName)"
            return
        }
        profileNotice = "已切换到 \(candidate.activeProfile?.name ?? "Profile")，快捷键立即生效"
        reload()
    }

    func createProfile(named name: String, copyingActive: Bool) {
        mutateProfiles { config in
            _ = try config.createProfile(
                named: name, copying: copyingActive ? config.activeProfileID : nil
            )
        }
    }

    func duplicateActiveProfile() {
        let base = activeProfileName
        createProfile(named: uniqueProfileName(base + " copy"), copyingActive: true)
    }

    func renameActiveProfile(to name: String) {
        mutateProfiles { config in
            guard let id = config.activeProfileID else {
                throw ShortcutProfileError.missingActiveProfile
            }
            try config.renameProfile(id, to: name)
        }
    }

    func deleteActiveProfile() {
        guard profiles.count > 1 else {
            profileNotice = "至少要保留一个 Profile"
            return
        }
        mutateProfiles { config in
            guard let id = config.activeProfileID, config.deleteProfile(id) else {
                throw ShortcutProfileError.noProfiles
            }
        }
    }

    func importTemplate(_ template: ShortcutProfileTemplate) {
        guard let delegate else { return }
        var candidate = delegate.currentConfig
        let result = candidate.importTemplate(template)
        guard delegate.saveConfig(candidate) else {
            profileNotice = "模板导入失败，原配置没有改变"
            return
        }
        profileNotice = result.importedCount == 0
            ? "没有可导入的快捷键；现有按键和目标均已保留"
            : "已导入 \(result.importedCount) 项；跳过 \(result.skippedOccupiedKeys.count) 个占用键"
        reload()
    }

    func exportProfiles() {
        guard let delegate else { return }
        do {
            let data = try ConfigStore.exportProfiles(delegate.currentConfig)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Hyper Shortcuts.json"
            panel.title = "导出快捷键 Profiles"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            profileNotice = "已导出 \(profiles.count) 个 Profiles"
        } catch {
            profileNotice = "导出失败：\(error.localizedDescription)"
        }
    }

    func importProfiles() {
        guard let delegate else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "导入快捷键 Profiles"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let current = delegate.currentConfig
        isImportingProfiles = true
        profileNotice = "正在后台验证导入文件…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try ConfigStore.readProfileArchive(at: url)
                let candidate = try ConfigStore.importProfiles(data, into: current)
                guard let preview = ProfileImportPreview.make(current: current, candidate: candidate) else {
                    throw ShortcutProfileError.missingActiveProfile
                }
                DispatchQueue.main.async {
                    self?.isImportingProfiles = false
                    self?.pendingProfileImport = preview
                    self?.profileNotice = "验证通过；确认预览后才会替换现有 Profiles"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isImportingProfiles = false
                    self?.profileNotice = "导入被拒绝：\(error.localizedDescription)；原配置没有改变"
                }
            }
        }
    }

    func cancelPendingProfileImport() {
        pendingProfileImport = nil
    }

    func commitPendingProfileImport() {
        guard let preview = pendingProfileImport, let delegate else { return }
        let current = delegate.currentConfig
        guard current.profiles == preview.baselineProfiles,
              current.activeProfileID == preview.baselineActiveProfileID else {
            profileNotice = "预览期间快捷键配置已变化，请重新选择文件生成新预览"
            pendingProfileImport = nil
            return
        }
        guard ConfigStore.saveImportRecovery(current) else {
            profileNotice = "无法创建恢复点，导入已取消；原配置没有改变"
            pendingProfileImport = nil
            refreshProfileRecoveryState()
            return
        }
        var candidate = current
        candidate.profiles = preview.profiles
        candidate.activeProfileID = preview.activeProfileID
        candidate.rebuildRuntimeBindings()
        guard delegate.saveConfig(candidate) else {
            profileNotice = "导入写入失败，原配置没有改变；恢复点已保留"
            pendingProfileImport = nil
            refreshProfileRecoveryState()
            return
        }
        pendingProfileImport = nil
        profileNotice = "已导入 \(candidate.profiles.count) 个 Profiles；可随时恢复导入前配置"
        reload()
    }

    func restoreImportRecovery() {
        guard let delegate else { return }
        do {
            let restored = try ConfigStore.loadImportRecovery(into: delegate.currentConfig)
            guard delegate.saveConfig(restored) else {
                profileNotice = "恢复写入失败，当前配置没有改变"
                return
            }
            ConfigStore.clearImportRecovery()
            profileNotice = "已恢复到导入前的 Profiles"
            reload()
        } catch {
            profileNotice = "恢复失败：\(error.localizedDescription)"
            refreshProfileRecoveryState()
        }
    }

    func restoreDowngradeRecovery() {
        guard let delegate else { return }
        do {
            let restored = try ConfigStore.loadDowngradeRecovery(into: delegate.currentConfig)
            guard delegate.saveConfig(restored) else {
                profileNotice = "恢复写入失败，当前配置没有改变"
                return
            }
            profileNotice = "已从兼容快照恢复 \(restored.profiles.count) 个 Profiles"
            reload()
        } catch {
            profileNotice = "恢复失败：\(error.localizedDescription)"
            refreshProfileRecoveryState()
        }
    }

    private func refreshProfileRecoveryState() {
        hasImportRecovery = ConfigStore.hasImportRecovery
        hasDowngradeRecovery = ConfigStore.hasDowngradeRecovery
        if hasDowngradeRecovery, profileNotice == nil {
            profileNotice = "发现可恢复的完整 Profile 快照；可在“导入 / 导出”菜单中确认恢复"
        }
    }

    func repair(_ conflict: ShortcutConflict) {
        switch conflict.kind {
        case .duplicateKey:
            for id in conflict.bindingIDs.dropFirst() {
                guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                rows[index].key = suggestAvailableKey()
            }
        case .systemReservedKey:
            guard let id = conflict.bindingIDs.first,
                  let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index].key = suggestAvailableKey()
        case .duplicateBuiltinAction:
            for id in conflict.bindingIDs.dropFirst() { rows.removeAll { $0.id == id } }
        case .unknownBuiltinAction, .missingApplication:
            let ids = Set(conflict.bindingIDs)
            rows.removeAll { ids.contains($0.id) }
        }
        sortRows()
        save()
        profileNotice = "已修复：\(conflict.explanation)"
    }

    private func suggestAvailableKey() -> String {
        let taken = Set(rows.compactMap { Keys.canonicalName(for: $0.key) })
        let candidates = (UInt8(ascii: "a")...UInt8(ascii: "z")).map {
            String(UnicodeScalar($0))
        } + (UInt8(ascii: "0")...UInt8(ascii: "9")).map { String(UnicodeScalar($0)) }
        return candidates.first { !taken.contains($0) } ?? "f18"
    }

    private func uniqueProfileName(_ base: String) -> String {
        let names = Set(profiles.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func mutateProfiles(_ mutation: (inout Config) throws -> Void) {
        guard let delegate else { return }
        var candidate = delegate.currentConfig
        do {
            try mutation(&candidate)
            guard delegate.saveConfig(candidate) else {
                profileNotice = "配置写入失败，原 Profile 保持不变"
                return
            }
            reload()
        } catch {
            profileNotice = error.localizedDescription
        }
    }

    // MARK: - Bindings

    func loadCatalogIfNeeded() {
        guard catalog.isEmpty else { return }
        AppCatalog.scan { [weak self] apps in self?.catalog = apps }
    }

    var boundTargets: Set<String> { Set(rows.map(\.target)) }

    func add(_ app: InstalledApp) {
        guard !rows.contains(where: { $0.target == app.target }) else { return }
        rows.append(makeRow(key: suggestKey(for: app.name), target: app.target))
        sortRows()
        save()
    }

    /// Fallback for applications outside the folders the catalog scans.
    func addFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        panel.message = "选择要绑定快捷键的应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let target = Bundle(url: url)?.bundleIdentifier ?? url.path
        guard !rows.contains(where: { $0.target == target }) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        rows.append(makeRow(key: suggestKey(for: name), target: target))
        sortRows()
        save()
    }

    func remove(_ row: BindingRow) {
        rows.removeAll { $0.id == row.id }
        save()
    }

    func setKey(_ key: String, for row: BindingRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }), rows[index].key != key
        else { return }
        rows[index].key = key
        sortRows()
        save()
    }

    /// Built-in actions first, then applications by name. They are a different kind of
    /// thing from "open an app", and mixing them alphabetically buries them.
    private func sortRows() {
        rows.sort { lhs, rhs in
            switch (lhs.action, rhs.action) {
            case (.some(let a), .some(let b)):
                let order = BuiltinAction.allCases
                return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    /// Prefers the application's own initial, then any free letter, so a freshly added
    /// row is usable immediately without silently colliding with an existing binding.
    private func suggestKey(for name: String) -> String {
        let taken = Set(rows.map(\.key))
        let letters = (UInt8(ascii: "a")...UInt8(ascii: "z")).map { String(UnicodeScalar($0)) }
        if let initial = name.lowercased().first.map(String.init),
           letters.contains(initial), !taken.contains(initial) {
            return initial
        }
        let digits = (UInt8(ascii: "0")...UInt8(ascii: "9")).map { String(UnicodeScalar($0)) }
        return (letters + digits).first { !taken.contains($0) } ?? "a"
    }

    private func makeRow(id: UUID = UUID(), key: String, target: String) -> BindingRow {
        if let action = BuiltinAction(rawValue: target) {
            return BindingRow(
                id: id,
                key: key,
                target: target,
                displayName: action.displayName,
                subtitle: action.detail,
                icon: NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil),
                missing: false,
                action: action
            )
        }

        let isPath = target.hasPrefix("/") || target.hasSuffix(".app")
        let url: URL? = isPath
            ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return BindingRow(id: id, key: key, target: target,
                              displayName: target, subtitle: "找不到这个应用",
                              icon: nil, missing: true)
        }
        // Same shared instance the menu bar and the clipboard panel draw, so it is left
        // at its natural size; the row scales it with `.resizable().frame(…)`.
        let icon = isPath
            ? AppIconCache.shared.fileIcon(path: url.path)
            : AppIconCache.shared.appIcon(bundleID: target)
        return BindingRow(
            id: id,
            key: key,
            target: target,
            displayName: url.deletingPathExtension().lastPathComponent,
            subtitle: target,
            icon: icon,
            missing: false
        )
    }

    // MARK: - System

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestAccessibility() {
        Permissions.requestTrust()
        Permissions.openAccessibilitySettings()
    }

    // MARK: - Recording window

    /// Hands the user a real F18 key for a while, so they can record it in whatever
    /// application should react to a tap. See `HIDRemapper.beginRecordingWindow`.
    func startRecordingWindow(seconds: Int = 20) {
        HIDRemapper.beginRecordingWindow(seconds: TimeInterval(seconds))
        recordingSecondsLeft = seconds
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            recordingSecondsLeft -= 1
            if recordingSecondsLeft <= 0 {
                timer.invalidate()
                self.recordingTimer = nil
            }
        }
    }

    func cancelRecordingWindow() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingSecondsLeft = 0
        HIDRemapper.endRecordingWindow()
    }
}
