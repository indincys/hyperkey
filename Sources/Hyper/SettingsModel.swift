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

/// Backing store for the settings window. Every mutation writes the file, so there is
/// no "unsaved" state that can drift from what the tap is actually using.
final class SettingsModel: ObservableObject {
    @Published private(set) var rows: [BindingRow] = []
    /// Precomputed so the list body stays O(n) instead of rescanning per row.
    @Published private(set) var duplicateKeys: Set<String> = []

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
    @Published var restoreAfterPaste = false
    @Published var joinSeparator = "\n"
    @Published private(set) var clipboardCount = 0
    @Published private(set) var pinnedCount = 0
    @Published private(set) var diskUsage: String = "—"

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
        restoreAfterPaste = config.clipboard.restoreAfterPaste
        joinSeparator = config.clipboard.joinSeparator

        // The file stores bindings sorted by key; the list shows them by application
        // name. Sorting here keeps the order stable when the file changes underneath us.
        rows = config.bindingNames.map { makeRow(key: $0.key, target: $0.target) }
        sortRows()
        recomputeDuplicates()
        refreshClipboardStats()
        refreshStatus()
    }

    // MARK: - Clipboard

    func refreshClipboardStats() {
        let store = ClipboardManager.shared.store
        clipboardCount = store.records.count
        pinnedCount = store.records.reduce(0) { $0 + ($1.pinned ? 1 : 0) }
        store.diskUsage { [weak self] bytes in
            self?.diskUsage = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
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
        config.clipboard = ClipboardSettings(
            enabled: clipboardEnabled,
            retentionDays: retentionDays,
            maxItems: maxItems,
            maxItemMB: maxItemMB,
            recordImages: recordImages,
            skipConcealed: skipConcealed,
            skipTransient: skipTransient,
            restoreAfterPaste: restoreAfterPaste,
            joinSeparator: joinSeparator
        )
        config.setBindings(rows.map { (key: $0.key, target: $0.target) })
        delegate.saveConfig(config)
        recomputeDuplicates()
    }

    private func recomputeDuplicates() {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for row in rows where !seen.insert(row.key).inserted {
            duplicates.insert(row.key)
        }
        duplicateKeys = duplicates
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

    private func makeRow(key: String, target: String) -> BindingRow {
        if let action = BuiltinAction(rawValue: target) {
            return BindingRow(
                id: UUID(),
                key: key,
                target: target,
                displayName: action.displayName,
                subtitle: action.detail,
                icon: NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil),
                missing: false,
                action: action
            )
        }

        let url: URL? = target.hasPrefix("/") || target.hasSuffix(".app")
            ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return BindingRow(id: UUID(), key: key, target: target,
                              displayName: target, subtitle: "找不到这个应用",
                              icon: nil, missing: true)
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return BindingRow(
            id: UUID(),
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
