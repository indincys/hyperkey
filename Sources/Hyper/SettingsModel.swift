import Cocoa
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct BindingRow: Identifiable, Equatable {
    let id: UUID
    var key: String
    /// Bundle identifier, or an absolute path for applications outside the usual folders.
    var target: String
    var displayName: String
    var icon: NSImage?
    var missing: Bool

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
    @Published var toggleHideIfFrontmost = true
    @Published var debug = false
    @Published var tapActionRaw = "none"
    @Published var tapThresholdMs = 200
    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityGranted = true
    @Published private(set) var tapRunning = false
    @Published private(set) var updateStatus: String?
    @Published private(set) var inApplicationsFolder = true

    @Published var isPickingApp = false
    @Published private(set) var catalog: [InstalledApp] = []

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
        toggleHideIfFrontmost = config.toggleHideIfFrontmost
        debug = config.debug
        tapActionRaw = config.tapActionRaw
        tapThresholdMs = config.tapThresholdMs
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // The file stores bindings sorted by key; the list shows them by application
        // name. Sorting here keeps the order stable when the file changes underneath us.
        rows = config.bindingNames.map { makeRow(key: $0.key, target: $0.target) }
        sortRows()
        recomputeDuplicates()
        refreshStatus()
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
        config.toggleHideIfFrontmost = toggleHideIfFrontmost
        config.debug = debug
        config.tapActionRaw = tapActionRaw
        config.tapAction = TapAction(rawValue: tapActionRaw)
        config.tapThresholdMs = tapThresholdMs
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

    private func sortRows() {
        rows.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
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
        let url: URL? = target.hasPrefix("/") || target.hasSuffix(".app")
            ? URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return BindingRow(id: UUID(), key: key, target: target,
                              displayName: target, icon: nil, missing: true)
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return BindingRow(
            id: UUID(),
            key: key,
            target: target,
            displayName: url.deletingPathExtension().lastPathComponent,
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
}
