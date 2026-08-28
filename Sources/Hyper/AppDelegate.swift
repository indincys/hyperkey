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

    /// Whether the status item's menu is on screen right now, and whether what it holds
    /// has gone stale since it was built. See `refreshMenu`.
    private var menuIsOpen = false
    private var menuNeedsRebuild = true

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

        AppLauncher.shared.updateFrontmost(NSWorkspace.shared.frontmostApplication)
        startTapIfPermitted()
        seedClipboardBindingsIfNeeded()
        observeClipboardQueue()

        // A menu-bar-only app shows nothing on launch. Without the accessibility
        // permission it also does nothing at all, so silently sitting in the menu bar
        // leaves the user with no idea what went wrong — put the setup screen in front
        // of them. Same on a first run, so the bindings are discoverable.
        if firstRun || !Permissions.isTrusted { openSettings() }

        scheduleUpdateChecks()

        // Local visual-QA seam. A SwiftPM debug executable has no status-item gesture
        // available to screenshot automation, so an explicit environment variable can
        // reveal the real clipboard panel without changing any production launch path.
        if ProcessInfo.processInfo.environment["HYPER_SHOW_CLIPBOARD_PANEL"] == "1" {
            DispatchQueue.main.async { ClipboardManager.shared.togglePanel() }
        }
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
            // `refreshMenu` keeps the badge live on its own.
            self?.refreshMenu()
        }
        NotificationCenter.default.addObserver(
            forName: ClipboardManager.privacyStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshMenu()
            self?.settingsWindow?.configDidChangeExternally()
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
            AppLauncher.shared.updateFrontmost(app)
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
        let previous = HyperTap.shared.config
        if previous.activeProfileID != config.activeProfileID
            || previous.bindingNames.map({ [$0.key, $0.target] })
                != config.bindingNames.map({ [$0.key, $0.target] }) {
            // A key-up interpreted against a different profile than its swallowed
            // key-down can leak or double-trigger. Clear the hold before replacing the
            // complete value; both operations run on the tap's main run loop.
            HyperTap.shared.resetState()
        }
        HyperTap.shared.config = config
        AppLauncher.shared.invalidateCache()
        bindingDisplayCache.removeAll()
        ClipboardManager.shared.apply(config.clipboard, applicationEnabled: config.enabled)
        log.info("config loaded: \(config.bindings.count) bindings")
        refreshMenu()
    }

    /// Writes config from the settings UI without bouncing it back through the file
    /// watcher, which would reload what we already have.
    @discardableResult
    func saveConfig(_ config: Config) -> Bool {
        savingConfig = true
        guard ConfigStore.save(config) else {
            savingConfig = false
            configError = "配置写入失败"
            refreshMenu()
            return false
        }
        let previous = HyperTap.shared.config
        if previous.activeProfileID != config.activeProfileID
            || previous.bindingNames.map({ [$0.key, $0.target] })
                != config.bindingNames.map({ [$0.key, $0.target] }) {
            HyperTap.shared.resetState()
        }
        HyperTap.shared.config = config
        AppLauncher.shared.invalidateCache()
        bindingDisplayCache.removeAll()
        ClipboardManager.shared.apply(config.clipboard, applicationEnabled: config.enabled)
        configError = nil
        refreshMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.savingConfig = false }
        return true
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
        menuIsOpen = true
        // Whatever is in the menu was built before this open, and the recent-clips
        // submenu follows a store nothing here observes — so treat it as stale
        // unconditionally. Marking it before the permission re-check also means that
        // check's own refresh does the rebuild instead of doubling it.
        menuNeedsRebuild = true
        if Permissions.isTrusted, !HyperTap.shared.isRunning { startTapIfPermitted() }
        if menuNeedsRebuild { rebuildMenu() }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    /// The entry point for everything that changes what the menu would say.
    ///
    /// Rebuilding means an item and an icon per binding plus a walk of the clipboard
    /// history, and `setUpdateStatus` alone calls in here once per percent of a
    /// download — all of it invisible while the menu is closed, and thrown away by the
    /// unconditional rebuild in `menuWillOpen` anyway. So a closed menu only remembers
    /// that it drifted.
    private func refreshMenu() {
        // The badge sits on the status item itself, not in the menu, so it stays live
        // whether or not anything is on screen.
        refreshStatusItemBadge()
        guard menuIsOpen else {
            menuNeedsRebuild = true
            return
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menuNeedsRebuild = false
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

        if config.profiles.count > 1 {
            let profileItem = NSMenuItem(
                title: "Profile：\(config.activeProfile?.name ?? "Default")",
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu(title: "快捷键 Profiles")
            for profile in config.profiles {
                let row = NSMenuItem(
                    title: profile.name,
                    action: #selector(switchProfileFromMenu(_:)),
                    keyEquivalent: ""
                )
                row.target = self
                row.representedObject = profile.id.uuidString
                row.state = profile.id == config.activeProfileID ? .on : .off
                submenu.addItem(row)
            }
            profileItem.submenu = submenu
            menu.addItem(profileItem)
        }

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
            if let pause = ClipboardManager.shared.pauseState {
                menu.addItem(disabledItem("剪贴板记录已暂停 · \(pause.reason.label)"))
                let formatter = DateFormatter()
                formatter.doesRelativeDateFormatting = true
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                menu.addItem(disabledItem("自动恢复：\(formatter.string(from: pause.resumesAt))"))
                menu.addItem(item("立即恢复剪贴板记录", #selector(resumeClipboardCapture)))
            } else {
                let pauseItem = NSMenuItem(
                    title: "临时暂停剪贴板记录", action: nil, keyEquivalent: ""
                )
                let submenu = NSMenu()
                submenu.addItem(item("15 分钟", #selector(pauseClipboard15Minutes)))
                submenu.addItem(item("1 小时", #selector(pauseClipboardOneHour)))
                submenu.addItem(item("自定义…", #selector(pauseClipboardCustom)))
                pauseItem.submenu = submenu
                menu.addItem(pauseItem)
            }
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

    /// Name for one binding target, plus whether it can be launched at all.
    ///
    /// No icon: those come from `AppIconCache`, which already memoises exactly these
    /// lookups for the clipboard panel — a third private image cache next to it would
    /// only pay for the same `.icns` decode twice.
    private struct BindingDisplay {
        let name: String
        /// False when the application is not installed. The row is still listed — a
        /// binding that quietly disappeared would be harder to notice than a grey one.
        let available: Bool
    }

    /// LaunchServices lookups are not free, and the menu is rebuilt on every open.
    /// Resolution only changes when the config does, so cache it and clear it where the
    /// launcher's own cache is cleared.
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
            return BindingDisplay(name: action.displayName, available: true)
        case .path(let raw):
            let candidate = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            url = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        case .bundleID(let id):
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }

        guard let url else { return BindingDisplay(name: shortName(target), available: false) }
        return BindingDisplay(name: url.deletingPathExtension().lastPathComponent, available: true)
    }

    /// A 16pt icon for a menu row. `AppIconCache` hands back one shared instance per
    /// application — the same one the clipboard panel draws at 27pt — so resize a copy
    /// and never the original.
    private func bindingIcon(for target: String, available: Bool) -> NSImage? {
        guard available else { return symbolIcon("questionmark.app.dashed") }
        switch LaunchTarget(rawValue: target) {
        case .action(let action):
            return symbolIcon(action.symbolName)
        case .path(let raw):
            let path = (raw as NSString).expandingTildeInPath
            return menuSized(AppIconCache.shared.fileIcon(path: path))
        case .bundleID(let id):
            // The cache's miss set is exactly the "not found" case, so a nil here means
            // the same thing `available` does — fall back rather than draw nothing.
            guard let icon = AppIconCache.shared.appIcon(bundleID: id) else {
                return symbolIcon("questionmark.app.dashed")
            }
            return menuSized(icon)
        }
    }

    private func symbolIcon(_ name: String) -> NSImage? {
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func menuSized(_ icon: NSImage) -> NSImage? {
        guard let copy = icon.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private func bindingItem(key: String, target: String) -> NSMenuItem {
        let display = bindingDisplay(for: target)
        let title = bindingTitle(key: key, name: display.name, available: display.available)
        // A nil action is what AppKit greys out under `autoenablesItems`; setting
        // `isEnabled` alone would be overridden.
        //
        // `attributedTitle` is what gets drawn; `title` is only the plain fallback
        // (accessibility, menu search), so it is handed the same string rather than a
        // second hand-built copy of it.
        let menuItem = NSMenuItem(
            title: title.string,
            action: display.available ? #selector(activateBinding(_:)) : nil,
            keyEquivalent: ""
        )
        if display.available { menuItem.target = self }
        menuItem.representedObject = target
        menuItem.image = bindingIcon(for: target, available: display.available)
        menuItem.attributedTitle = title
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

    @objc private func switchProfileFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else {
            return
        }
        var config = currentConfig
        guard config.activateProfile(id) else { return }
        _ = saveConfig(config)
        settingsWindow?.configDidChangeExternally()
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
        // One pass over the history, not a linear scan of it per queued entry: a full
        // queue against a full history is otherwise thousands of comparisons every time
        // the menu opens.
        let byID = Dictionary(
            ClipboardManager.shared.store.records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // In dispensing order, which is the queue's own order.
        for id in ClipboardManager.shared.queue.ids {
            guard let record = byID[id] else { continue }
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
        return truncated(record.preview, limit: 40)
    }

    /// `preview` is already one collapsed line — `ClipCapture.makePreview` folds the
    /// whitespace and substitutes a placeholder for empty content when the record is
    /// written. All that is left is making it fit a menu row.
    private func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
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

    @objc private func pauseClipboard15Minutes() {
        setClipboardPause(minutes: 15)
    }

    @objc private func pauseClipboardOneHour() {
        setClipboardPause(minutes: 60)
    }

    @objc private func pauseClipboardCustom() {
        let alert = NSAlert()
        alert.messageText = "临时暂停剪贴板记录"
        alert.informativeText = "暂停期间零捕获；恢复时不会补录当前剪贴板。请输入 1–1440 分钟。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "暂停")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: "30")
        field.placeholderString = "分钟"
        field.alignment = .right
        field.setAccessibilityLabel("暂停分钟数")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(value), (1...(24 * 60)).contains(minutes) else {
            ClipboardHUD.shared.show(
                "请输入 1–1440 分钟", symbol: "exclamationmark.triangle", style: .warning
            )
            return
        }
        setClipboardPause(minutes: minutes)
    }

    @objc private func resumeClipboardCapture() {
        var config = HyperTap.shared.config
        config.clipboard.pauseUntil = nil
        guard saveConfig(config) else { return }
        settingsWindow?.configDidChangeExternally()
    }

    private func setClipboardPause(minutes: Int) {
        var config = HyperTap.shared.config
        let bounded = min(max(minutes, 1), 24 * 60)
        config.clipboard.pauseUntil = Date().addingTimeInterval(TimeInterval(bounded * 60))
        guard saveConfig(config) else { return }
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
