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
    private var clipboardNotice: String?
    private var savingConfig = false
    private var updateTimer: Timer?
    private(set) var updateStatus: String?
    /// Throttle state for the download progress readout; see `showDownloadProgress`.
    private var lastProgressFraction: Double = -1
    private var lastProgressShownAt = Date.distantPast

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
        seedClipboardBindingsIfNeeded()
        observeClipboardQueue()

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
        ClipboardManager.shared.applicationWillTerminate()
    }

    // MARK: - Clipboard

    /// Gives an existing install the clipboard bindings, once, and only on keys that
    /// are still free. Silently repurposing a key someone already uses would be a
    /// worse upgrade than not shipping the feature.
    private func seedClipboardBindingsIfNeeded() {
        var config = HyperTap.shared.config
        guard !config.clipboardBindingsSeeded else { return }
        let skipped = config.seedClipboardBindings()
        saveConfig(config)

        guard !skipped.isEmpty else { return }
        let names = skipped.map(\.displayName).joined(separator: "、")
        clipboardNotice = "「\(names)」没有默认快捷键（首选键已被占用），可在设置里指定"
        log.info("clipboard bindings partially skipped: \(names, privacy: .public)")
        refreshMenu()
    }

    private func observeClipboardQueue() {
        NotificationCenter.default.addObserver(
            forName: ClipboardManager.queueChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshStatusItemBadge()
            self?.refreshMenu()
        }
    }

    /// The menu bar is the only place a queue that is waiting to be dispensed is
    /// visible, so it carries the count.
    private func refreshStatusItemBadge() {
        guard let button = statusItem?.button else { return }
        let depth = ClipboardManager.shared.queue.count
        button.title = depth > 0 ? " \(depth)" : ""
        button.imagePosition = depth > 0 ? .imageLeading : .imageOnly
    }

    @objc private func openClipboardPanel() {
        ClipboardManager.shared.togglePanel()
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
        alert.informativeText = "当前版本 \(Hyper.version)。更新会在下载完成后自动重启 Hyper。"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            // Release notes belong in a scrollable view, not in `informativeText`:
            // truncating them was the difference between "here is what changed" and
            // "here is the first paragraph of what changed".
            alert.accessoryView = releaseNotesView(notes)
        }
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "以后再说")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            setUpdateStatus(nil)
            return
        }
        startDownload(release)
    }

    /// Read-only, selectable, and scrolling. Still capped, but at a length nobody
    /// writes by hand — the cap is protection against a pathological release body,
    /// not an editorial decision.
    private func releaseNotesView(_ notes: String) -> NSView {
        let lines = notes.components(separatedBy: .newlines)
        let body = lines.count > 200
            ? lines.prefix(200).joined(separator: "\n") + "\n…"
            : notes

        let size = NSSize(width: 380, height: 200)
        let text = NSTextView(frame: NSRect(origin: .zero, size: size))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.string = body

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = text
        return scroll
    }

    private func startDownload(_ release: Release) {
        lastProgressFraction = -1
        lastProgressShownAt = .distantPast
        setUpdateStatus("正在下载 \(release.version)…")
        Updater.shared.downloadAndInstall(release) { [weak self] fraction, bytes in
            self?.showDownloadProgress(release, fraction: fraction, bytesWritten: bytes)
        } completion: { [weak self] failure in
            // Only called on failure; a success terminates the process.
            guard let self, let failure else { return }
            self.setUpdateStatus("更新失败")
            self.presentUpdateFailure(failure, release: release)
        }
    }

    /// Every status change rebuilds the whole menu, and a download reports progress
    /// many times a second — only redraw on a change someone could actually see.
    private func showDownloadProgress(_ release: Release, fraction: Double?, bytesWritten: Int64) {
        let now = Date()
        guard let fraction else {
            // No content length: elapsed volume is the only honest thing to show.
            guard now.timeIntervalSince(lastProgressShownAt) >= 0.5 else { return }
            lastProgressShownAt = now
            let size = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
            setUpdateStatus("正在下载 \(release.version)… \(size)")
            return
        }
        guard fraction - lastProgressFraction >= 0.01
                || now.timeIntervalSince(lastProgressShownAt) >= 0.5 else { return }
        lastProgressFraction = fraction
        lastProgressShownAt = now
        setUpdateStatus("正在下载 \(release.version)… \(Int(fraction * 100))%")
    }

    /// A failed update is nearly always a flaky network, so the first button offers
    /// the obvious remedy instead of sending the user back to GitHub.
    private func presentUpdateFailure(_ message: String, release: Release) {
        let alert = NSAlert()
        alert.messageText = "更新失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            startDownload(release)
        } else {
            setUpdateStatus(nil)
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
        bindingDisplayCache.removeAll()
        ClipboardManager.shared.apply(config.clipboard)
        log.info("config loaded: \(config.bindings.count) bindings")
        refreshMenu()
    }

    /// Writes config from the settings UI without bouncing it back through the file
    /// watcher, which would reload what we already have.
    func saveConfig(_ config: Config) {
        savingConfig = true
        HyperTap.shared.config = config
        AppLauncher.shared.invalidateCache()
        bindingDisplayCache.removeAll()
        ClipboardManager.shared.apply(config.clipboard)
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
        if let clipboardNotice {
            menu.addItem(disabledItem("ℹ️ \(clipboardNotice)"))
        }
        if let updateStatus {
            menu.addItem(disabledItem(updateStatus))
        }

        menu.addItem(.separator())
        if config.bindingNames.isEmpty {
            menu.addItem(disabledItem("（还没有配置任何快捷键）"))
        } else {
            // Every binding, not a truncated preview: each row is now a working
            // launcher, and the list is bounded by the keyboard anyway.
            for binding in config.bindingNames {
                menu.addItem(bindingItem(key: binding.key, target: binding.target))
            }
        }

        if config.clipboard.enabled {
            menu.addItem(.separator())
            menu.addItem(item("剪贴板历史…", #selector(openClipboardPanel)))
            if let recents = recentClipsMenu() {
                let parent = NSMenuItem(title: "最近复制", action: nil, keyEquivalent: "")
                parent.submenu = recents
                menu.addItem(parent)
            }
            let depth = ClipboardManager.shared.queue.count
            if depth > 0 {
                let parent = NSMenuItem(title: "批量队列：\(depth) 条待粘贴", action: nil, keyEquivalent: "")
                parent.submenu = queueMenu()
                menu.addItem(parent)
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

    // MARK: - Menu bar / bindings

    /// Name and icon for one binding target, plus whether it can be launched at all.
    private struct BindingDisplay {
        let name: String
        let icon: NSImage?
        /// False when the application is not installed. The row is still listed — a
        /// binding that quietly disappeared would be harder to notice than a grey one.
        let available: Bool
    }

    /// LaunchServices lookups and icon reads are not free, and `refreshMenu` runs on
    /// every `menuWillOpen` as well as on every queue change. Resolution only changes
    /// when the config does, so cache it and clear it where the launcher's own cache
    /// is cleared.
    private var bindingDisplayCache: [String: BindingDisplay] = [:]

    private func bindingDisplay(for target: String) -> BindingDisplay {
        if let hit = bindingDisplayCache[target] { return hit }
        let display = resolveBindingDisplay(target)
        bindingDisplayCache[target] = display
        return display
    }

    private func resolveBindingDisplay(_ target: String) -> BindingDisplay {
        let url: URL?
        switch LaunchTarget(rawValue: target) {
        case .action(let action):
            let icon = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
            icon?.isTemplate = true
            icon?.size = NSSize(width: 16, height: 16)
            return BindingDisplay(name: action.displayName, icon: icon, available: true)
        case .path(let raw):
            let candidate = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            url = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        case .bundleID(let id):
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }

        guard let url else {
            let missing = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil)
            missing?.isTemplate = true
            missing?.size = NSSize(width: 16, height: 16)
            return BindingDisplay(name: shortName(target), icon: missing, available: false)
        }

        // NSWorkspace hands back a shared instance; resizing it in place would resize
        // the copy every other caller sees too.
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        return BindingDisplay(
            name: url.deletingPathExtension().lastPathComponent, icon: icon, available: true
        )
    }

    private func bindingItem(key: String, target: String) -> NSMenuItem {
        let display = bindingDisplay(for: target)
        // A nil action is what AppKit greys out under `autoenablesItems`; setting
        // `isEnabled` alone would be overridden.
        let menuItem = NSMenuItem(
            title: "⇪ + \(Keys.display(forName: key))",
            action: display.available ? #selector(activateBinding(_:)) : nil,
            keyEquivalent: ""
        )
        if display.available { menuItem.target = self }
        menuItem.representedObject = target
        menuItem.image = display.icon
        menuItem.attributedTitle = bindingTitle(
            key: key, name: display.name, available: display.available
        )
        menuItem.toolTip = target
        return menuItem
    }

    /// The key on the left, the target name on the right. Deliberately carries no
    /// colours: without them AppKit still applies its own highlight and disabled
    /// appearance, which an explicit foreground colour would freeze in place.
    private func bindingTitle(key: String, name: String, available: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // One tab stop, so the names line up however wide the key label is.
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 96, options: [:])]
        let title = NSMutableAttributedString(
            string: "⇪ + \(Keys.display(forName: key))\t",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph]
        )
        title.append(NSAttributedString(
            string: available ? name : "\(name)（未找到）",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraph,
            ]
        ))
        return title
    }

    @objc private func activateBinding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        switch LaunchTarget(rawValue: raw) {
        case .action(let action):
            ClipboardManager.shared.perform(action)
        case let target:
            // No repeat-press behaviour from the menu: clicking a row means "show me
            // this", and hiding or cycling from here would be a surprise.
            AppLauncher.shared.activate(target, repeatPress: .none)
        }
    }

    // MARK: - Menu bar / clipboard

    /// The last few entries, copy-on-click. Nil when there is no history, so an empty
    /// submenu never appears.
    private func recentClipsMenu() -> NSMenu? {
        let records = Array(ClipboardManager.shared.store.records.prefix(5))
        guard !records.isEmpty else { return nil }

        let menu = NSMenu()
        for record in records {
            let menuItem = NSMenuItem(
                title: clipLabel(record), action: #selector(copyRecentClip(_:)), keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = record.id
            menu.addItem(menuItem)
        }
        return menu
    }

    private func queueMenu() -> NSMenu {
        let menu = NSMenu()
        let store = ClipboardManager.shared.store
        // In dispensing order, which is the queue's own order.
        for id in ClipboardManager.shared.queue.ids {
            guard let record = store.record(id: id) else { continue }
            menu.addItem(disabledItem(clipLabel(record)))
        }
        menu.addItem(.separator())
        menu.addItem(item("清空队列", #selector(clearPasteQueue)))
        return menu
    }

    /// One menu-width line for a history entry. No thumbnail lookup: that is disk IO,
    /// and this runs every time the menu opens.
    private func clipLabel(_ record: ClipRecord) -> String {
        if record.kind == .image {
            if let width = record.pixelWidth, let height = record.pixelHeight {
                return "图片 \(width)×\(height)"
            }
            return "图片"
        }
        return singleLine(record.preview, limit: 40)
    }

    private func singleLine(_ text: String, limit: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if flattened.isEmpty { return "（空白内容）" }
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }

    @objc private func copyRecentClip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = ClipboardManager.shared.store.record(id: id) else { return }
        ClipboardManager.shared.copyToClipboard(record, plainTextOnly: false)
    }

    @objc private func clearPasteQueue() {
        ClipboardManager.shared.clearQueue()
    }

    private func shortName(_ target: String) -> String {
        if let action = BuiltinAction(rawValue: target) { return action.displayName }
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
