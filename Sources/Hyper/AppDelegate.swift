import Cocoa
import os
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = Logger(subsystem: Hyper.subsystem, category: "app")

    private var statusItem: NSStatusItem!
    private var configWatcher: ConfigWatcher?
    private var signalSources: [DispatchSourceSignal] = []
    private var settingsWindow: SettingsWindowController?
    private var configError: String?
    private var savingConfig = false
    private var updateTimer: Timer?
    private(set) var updateStatus: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else: this can relaunch us from /Applications and terminate
        // this process, so nothing should have registered state or grabbed the HID
        // mapping yet.
        if InstallLocation.offerToMoveIfNeeded() { return }

        let firstRun = !FileManager.default.fileExists(atPath: ConfigStore.url.path)
        ConfigStore.writeDefaultIfMissing()
        reloadConfig()
        buildStatusItem()

        HIDRemapper.applyAsync()
        HIDRemapper.startWatchingDevices()

        configWatcher = ConfigWatcher { [weak self] in
            guard let self, !self.savingConfig else { return }
            self.reloadConfig()
            self.settingsWindow?.configDidChangeExternally()
        }

        observeWorkspace()
        observeAccessibilityChanges()
        installSignalHandlers()

        AppLauncher.shared.updateFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        startTapIfPermitted()

        // A menu-bar-only app shows nothing on launch. Without the accessibility
        // permission it also does nothing at all, so silently sitting in the menu bar
        // leaves the user with no idea what went wrong — put the setup screen in front
        // of them. Same on a first run, so the bindings are discoverable.
        if firstRun || !Permissions.isTrusted { openSettings() }

        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HyperTap.shared.stop()
        HIDRemapper.restore()
    }

    // MARK: - Permission

    /// Starts the tap if allowed. Everything that could change the answer — the
    /// accessibility database changing, the user coming back from System Settings,
    /// opening the menu — calls back in here. Nothing polls.
    private func startTapIfPermitted() {
        if Permissions.isTrusted {
            if !HyperTap.shared.isRunning { _ = HyperTap.shared.start() }
        } else {
            log.info("accessibility permission not granted yet")
        }
        refreshMenu()
        settingsWindow?.refreshStatus()
    }

    private func observeAccessibilityChanges() {
        // Posted by the system whenever the accessibility permission database changes.
        // The change needs a moment to become visible to AXIsProcessTrusted.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.startTapIfPermitted() }
        }
    }

    func requestPermission() {
        Permissions.requestTrust()
    }

    // MARK: - Observers

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            HyperTap.shared.resetState()
        }

        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            HyperTap.shared.resetState()
            HIDRemapper.scheduleReapply(delay: 1.5)
            self?.startTapIfPermitted()
        }

        // Note what is in front so a second press of the same binding can hide it.
        // This must NOT reset the hyper state: activating an application is the normal
        // result of using this tool, and resetting here would cancel the hyper key the
        // user is still physically holding down.
        workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            AppLauncher.shared.updateFrontmost(app?.bundleIdentifier)
            // Coming back from System Settings is the usual way permission gets granted.
            if !HyperTap.shared.isRunning { self?.startTapIfPermitted() }
        }

        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributed.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { _ in
                HyperTap.shared.resetState()
            }
        }
    }

    /// Being killed rather than quit would leave Caps Lock remapped to a key that no
    /// longer does anything. Route the usual termination signals through the normal
    /// shutdown so the mapping is always restored.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Updates

    private func scheduleUpdateChecks() {
        // A little after launch, so it never competes with getting the tap running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        setUpdateStatus(userInitiated ? "正在检查更新…" : nil)
        Updater.shared.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .upToDate:
                self.setUpdateStatus(userInitiated ? "已经是最新版本（\(Hyper.version)）" : nil)
            case .available(let release):
                self.setUpdateStatus("发现新版本 \(release.version)")
                self.promptForUpdate(release)
            case .failed(let message):
                self.setUpdateStatus(userInitiated ? "检查失败：\(message)" : nil)
            }
        }
    }

    private func promptForUpdate(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.version)"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? "当前版本 \(Hyper.version)。更新会在下载完成后自动重启 Hyper。"
            : "当前版本 \(Hyper.version)。\n\n\(String(notes.prefix(600)))"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "以后再说")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            setUpdateStatus(nil)
            return
        }

        setUpdateStatus("正在下载 \(release.version)…")
        Updater.shared.downloadAndInstall(release) { [weak self] failure in
            // Only called on failure; a success terminates the process.
            guard let failure else { return }
            self?.setUpdateStatus("更新失败")
            let alert = NSAlert()
            alert.messageText = "更新失败"
            alert.informativeText = failure
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func setUpdateStatus(_ text: String?) {
        updateStatus = text
        refreshMenu()
        settingsWindow?.refreshStatus()
    }

    // MARK: - Config

    private func reloadConfig() {
        guard let config = ConfigStore.load() else {
            configError = "配置文件 JSON 有误，仍在使用上一份配置"
            log.error("config parse failed; previous bindings retained")
            refreshMenu()
            return
        }
        configError = nil
        HyperTap.shared.config = config
        AppLauncher.shared.invalidateCache()
        log.info("config loaded: \(config.bindings.count) bindings")
        refreshMenu()
    }

    /// Writes config from the settings UI without bouncing it back through the file
    /// watcher, which would reload what we already have.
    func saveConfig(_ config: Config) {
        savingConfig = true
        HyperTap.shared.config = config
        AppLauncher.shared.invalidateCache()
        configError = ConfigStore.save(config) ? nil : "配置写入失败"
        refreshMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.savingConfig = false }
    }

    var currentConfig: Config { HyperTap.shared.config }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "capslock.fill", accessibilityDescription: "Hyper")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshMenu()
    }

    /// Opening the menu is a free chance to re-check state — no timer required.
    func menuWillOpen(_ menu: NSMenu) {
        if Permissions.isTrusted, !HyperTap.shared.isRunning { startTapIfPermitted() }
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let config = HyperTap.shared.config
        let status: String
        if !Permissions.isTrusted {
            status = "⚠️ 需要「辅助功能」权限"
        } else if !HyperTap.shared.isRunning {
            status = "⚠️ 事件监听未启动"
        } else if !config.enabled {
            status = "已暂停"
        } else {
            status = "运行中"
        }
        menu.addItem(disabledItem("Hyper \(Hyper.version) — \(status)"))

        if !Permissions.isTrusted {
            menu.addItem(item("授予「辅助功能」权限…", #selector(grantPermission)))
        }
        if let configError {
            menu.addItem(disabledItem("⚠️ \(configError)"))
        }
        if let updateStatus {
            menu.addItem(disabledItem(updateStatus))
        }

        menu.addItem(.separator())
        if config.bindingNames.isEmpty {
            menu.addItem(disabledItem("（还没有配置任何快捷键）"))
        } else {
            for binding in config.bindingNames.prefix(12) {
                menu.addItem(disabledItem("  ⇪ + \(binding.key.uppercased())    \(shortName(binding.target))"))
            }
            if config.bindingNames.count > 12 {
                menu.addItem(disabledItem("  … 还有 \(config.bindingNames.count - 12) 条"))
            }
        }

        menu.addItem(.separator())
        let settings = item("设置…", #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(item(config.enabled ? "暂停" : "启用", #selector(toggleEnabled)))
        menu.addItem(item("检查更新…", #selector(checkUpdatesFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("退出 Hyper", #selector(quit)))
    }

    private func shortName(_ target: String) -> String {
        if target.hasSuffix(".app") {
            return (target as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            return url.deletingPathExtension().lastPathComponent
        }
        return target
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    // MARK: - Actions

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(delegate: self)
        }
        settingsWindow?.show()
    }

    @objc private func toggleEnabled() {
        var config = HyperTap.shared.config
        config.enabled.toggle()
        if !config.enabled { HyperTap.shared.resetState() }
        saveConfig(config)
        settingsWindow?.configDidChangeExternally()
    }

    @objc private func checkUpdatesFromMenu() {
        checkForUpdates(userInitiated: true)
    }

    @objc private func grantPermission() {
        Permissions.requestTrust()
        Permissions.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
