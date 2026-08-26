import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            if model.accessibilityGranted {
                MainSettings(model: model)
            } else {
                OnboardingView(model: model)
            }
        }
        .frame(width: 640, height: 580)
        .animation(.easeInOut(duration: 0.25), value: model.accessibilityGranted)
    }
}

// MARK: - Onboarding

/// Shown until accessibility is granted. Without that permission the tap cannot read a
/// single key, so there is nothing worth configuring yet — this replaces the settings
/// rather than sitting beside them.
private struct OnboardingView: View {
    @ObservedObject var model: SettingsModel

    private var karabinerInstalled: Bool {
        FileManager.default.fileExists(
            atPath: "/Library/Application Support/org.pqrs/Karabiner-Elements"
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "capslock.fill")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 18)

            Text("再一步就能用了")
                .font(.title2.weight(.semibold))

            Text("Hyper 需要「辅助功能」权限才能读到键盘。\n没有它，快捷键不会有任何反应。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)

            Button {
                model.requestAccessibility()
            } label: {
                Text("打开系统设置并授权")
                    .frame(maxWidth: 240)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 9) {
                stepRow(1, "在打开的窗口里找到 Hyper")
                stepRow(2, "把它的开关打开")
                stepRow(3, "回到这里 —— 会自动继续，不用重启")
            }
            .padding(.top, 26)

            if karabinerInstalled {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("检测到 Karabiner-Elements")
                            .font(.callout.weight(.medium))
                        Text("它的驱动会抢占键盘，Hyper 将收不到任何按键。请在它的 Settings → Devices 里取消勾选键盘，或彻底卸载。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: 420, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 24)
            }

            Spacer()

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在等待授权…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.secondary, in: Circle())
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Main

private struct MainSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            ShortcutsTab(model: model)
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            ClipboardTab(model: model)
                .tabItem { Label("剪贴板", systemImage: "clipboard") }
            GeneralTab(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(model: model)
            Divider()

            if model.rows.isEmpty {
                EmptyState { model.isPickingApp = true }
            } else {
                List {
                    ForEach(model.rows) { row in
                        BindingRowView(
                            row: row,
                            isDuplicate: model.duplicateKeys.contains(row.key),
                            onKeyChange: { model.setKey($0, for: row) },
                            onRemove: { model.remove(row) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack(spacing: 10) {
                Button {
                    model.isPickingApp = true
                } label: {
                    Label("添加应用", systemImage: "plus")
                }
                .controlSize(.large)

                if !model.unboundActions.isEmpty {
                    Menu {
                        ForEach(model.unboundActions, id: \.self) { action in
                            Button {
                                model.addAction(action)
                            } label: {
                                Label(action.displayName, systemImage: action.symbolName)
                            }
                        }
                    } label: {
                        Label("添加动作", systemImage: "sparkles")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("绑定 Hyper 自己的功能，比如剪贴板面板")
                }

                if !model.duplicateKeys.isEmpty {
                    Label("有按键重复，同一个键只会触发其中一个", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Text("\(model.rows.count) 个快捷键")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $model.isPickingApp) {
            AppPickerSheet(model: model)
        }
    }
}

private struct StatusStrip: View {
    @ObservedObject var model: SettingsModel

    private var state: (color: Color, text: String) {
        if !model.enabled { return (.orange, "已暂停") }
        if !model.tapRunning { return (.red, "事件监听未启动") }
        return (.green, "运行中")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            Text(state.text)
                .font(.callout.weight(.medium))
            Text("按住 Caps Lock 不放，再按下面的按键")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct BindingRowView: View {
    let row: BindingRow
    let isDuplicate: Bool
    let onKeyChange: (String) -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if row.action != nil {
                    // Built-in actions have no application icon, so they get a tinted
                    // glyph instead — which also marks them out from the app rows.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(
                            Image(nsImage: row.icon ?? NSImage())
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        )
                } else if let icon = row.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "questionmark.app.dashed")
                        .resizable().scaledToFit()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(row.missing ? Color.red : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("⇪")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("+")
                .font(.caption)
                .foregroundStyle(.tertiary)

            KeyRecorderField(
                keyName: row.key,
                isDuplicate: isDuplicate,
                onCapture: onKeyChange
            )
            .frame(width: 72, height: 28)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(hovering ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
            .help("删除这个快捷键")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct EmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有绑定任何应用")
                .font(.headline)
            Text("绑定之后，按住 Caps Lock 再按对应的键就能唤起它。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("添加第一个应用", action: onAdd)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App picker

private struct AppPickerSheet: View {
    @ObservedObject var model: SettingsModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [InstalledApp] {
        guard !query.isEmpty else { return model.catalog }
        return model.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.target.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索应用", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { add(first) } }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            if model.catalog.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                List(results) { app in
                    AppPickerRow(app: app, alreadyBound: model.boundTargets.contains(app.target))
                        .contentShape(Rectangle())
                        .onTapGesture { add(app) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack {
                Button("从访达选择…") {
                    model.isPickingApp = false
                    DispatchQueue.main.async { model.addFromFinder() }
                }
                Spacer()
                Button("完成") { model.isPickingApp = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 460, height: 470)
        .onAppear {
            model.loadCatalogIfNeeded()
            searchFocused = true
        }
    }

    private func add(_ app: InstalledApp) {
        model.add(app)
        query = ""
        searchFocused = true
    }
}

private struct AppPickerRow: View {
    let app: InstalledApp
    let alreadyBound: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 26, height: 26)
            Text(app.name)
                .lineLimit(1)
            Spacer()
            if alreadyBound {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("已经绑定过了")
            }
        }
        .opacity(alreadyBound ? 0.45 : 1)
        .padding(.vertical, 2)
    }
}

// MARK: - Clipboard

private struct ClipboardTab: View {
    @ObservedObject var model: SettingsModel

    private let separators: [(label: String, value: String)] = [
        ("换行", "\n"),
        ("空行", "\n\n"),
        ("空格", " "),
        ("逗号", ", "),
        ("制表符", "\t"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("记录剪贴板历史", isOn: bind(\.clipboardEnabled))
            } footer: {
                Text("关掉之后不再记录任何新内容，已经存下来的内容保持原样。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.clipboardEnabled {
                Section {
                    Stepper(value: bind(\.retentionDays), in: 1...365) {
                        LabeledContent("超过这些天就删掉") {
                            Text("\(model.retentionDays) 天").monospacedDigit()
                        }
                    }
                    Stepper(value: bind(\.maxItems), in: 50...5000, step: 50) {
                        LabeledContent("最多保留") {
                            Text("\(model.maxItems) 条").monospacedDigit()
                        }
                    }
                    Stepper(value: bind(\.maxItemMB), in: 1...200, step: 1) {
                        LabeledContent("单条上限") {
                            Text("\(model.maxItemMB) MB").monospacedDigit()
                        }
                    }
                } header: {
                    Text("保留多久")
                } footer: {
                    Text("两个条件谁先到就按谁执行，滚动淘汰最旧的。**收藏的内容不受影响，永远不会被自动清理。**\n超过单条上限的内容只留下一条记录，正文不保存——所以粘不回去。截图会先转成 PNG 再算大小，正常的 Retina 截图基本都在 10 MB 以内。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("记录图片", isOn: bind(\.recordImages))
                    Toggle("跳过密码管理器复制的内容", isOn: bind(\.skipConcealed))
                    Toggle("跳过标记为临时的内容", isOn: bind(\.skipTransient))
                } header: {
                    Text("记什么")
                } footer: {
                    Text("1Password、钥匙串这类工具会给复制出来的密码打一个「机密」标记，打开这个开关就不会记录它们。建议保持打开。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("粘贴后把原来的剪贴板内容还原回去", isOn: bind(\.restoreAfterPaste))
                    Picker("合并粘贴时的分隔符", selection: Binding(
                        get: { model.joinSeparator },
                        set: { model.joinSeparator = $0; model.save() }
                    )) {
                        ForEach(separators, id: \.value) { Text($0.label).tag($0.value) }
                    }
                } header: {
                    Text("粘贴")
                } footer: {
                    Text("关掉「还原」时，粘完之后剪贴板里就是你刚粘的东西——再按一次 ⌘V 还是它。\n在面板里 ⌘ 点选多条，按 ↩ 就会用这个分隔符把它们连成一段粘出去。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("现在存了") {
                        Text("\(model.clipboardCount) 条 · \(model.diskUsage)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("清空历史（保留收藏）") {
                            model.clearClipboardHistory(includingPinned: false)
                        }
                        Button("全部清空") {
                            model.clearClipboardHistory(includingPinned: true)
                        }
                        Spacer()
                        Button("在访达中显示") { model.revealClipboardFolder() }
                    }
                } footer: {
                    Text("存在 ~/.local/share/hyper/clipboard/，纯本地，不上传任何地方。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshClipboardStats() }
    }

    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.save() }
        )
    }
}

// MARK: - General

/// The way out of a chicken-and-egg problem: F18 is useful precisely because no keyboard
/// has that key, which also means it cannot be typed into another application's shortcut
/// recorder. This lends the user a real one for a few seconds.
private struct RecordingWindowRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if model.recordingSecondsLeft > 0 {
            HStack(spacing: 10) {
                Image(systemName: "record.circle").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("现在去对方的录制框里按一下 Caps Lock")
                        .font(.callout.weight(.medium))
                    Text("这几秒里 Caps Lock 就是 F18，Hyper 暂时不工作")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.recordingSecondsLeft)s")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Button("结束") { model.cancelRecordingWindow() }
            }
            .padding(.vertical, 2)
        } else {
            HStack {
                Text("在别的 app 里录 F18")
                Spacer()
                Button("借我 20 秒") { model.startRecordingWindow() }
            }
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    private var tapActionSelection: String {
        switch model.tapActionRaw {
        case "none", "": return "none"
        case "escape", "esc": return "escape"
        case "f18": return "f18"
        case "ctrl+cmd": return "ctrl+cmd"
        default: return "custom"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 Hyper", isOn: bind(\.enabled))
                Toggle("开机自动启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            } footer: {
                Text("关掉「启用」后 Caps Lock 仍然是 Hyper，只是不再触发任何快捷键。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("已在最前时再按一次", selection: bind(\.repeatPressRaw)) {
                    Text("隐藏它").tag(RepeatPress.hide.rawValue)
                    Text("循环它的窗口").tag(RepeatPress.cycle.rawValue)
                    Text("不做任何事").tag(RepeatPress.none.rawValue)
                }
            } footer: {
                Text("""
                选「隐藏它」，按住 Caps Lock 连按同一个键就能在「看一眼」和「切回去」之间来回切换。

                选「循环它的窗口」，连按会在这个应用自己的窗口之间轮流切换——适合一个应用开好几个窗口的情况，比如浏览器的多个窗口、编辑器的多个项目。最小化的窗口和面板不参与，只有一个窗口时按了也不动。
                """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("单击 Caps Lock", selection: Binding(
                    get: { tapActionSelection },
                    set: { newValue in
                        guard newValue != "custom" else { return }
                        model.tapActionRaw = newValue
                        model.save()
                    }
                )) {
                    Text("不做任何事").tag("none")
                    Text("Esc").tag("escape")
                    Text("发送 F18（给输入法等外部工具当触发键）").tag("f18")
                    Text("发送 ⌃⌘（给只认修饰键的录制框）").tag("ctrl+cmd")
                    if tapActionSelection == "custom" {
                        Text(model.tapActionRaw).tag("custom")
                    }
                }
                if tapActionSelection != "none" {
                    Stepper(value: bind(\.tapThresholdMs), in: 80...600, step: 20) {
                        HStack {
                            Text("判定为单击的时长上限")
                            Spacer()
                            Text("\(model.tapThresholdMs) ms").monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if tapActionSelection == "f18" {
                    RecordingWindowRow(model: model)
                }
            } footer: {
                Text("""
                「单击」指按下 Caps Lock 后没有按别的键、并在上面这个时长内松开。按住不放始终是 Hyper，永远不会触发这里的动作。

                想让单击去开别的东西（比如微信输入法的语音输入），选「发送 F18」，再到那个 app 里把它的快捷键录成 F18——没有哪块键盘上有 F18，不会跟别人抢。

                但也正因为没有哪块键盘上有，你没法直接把它按出来：在对方的录制框里按 Caps Lock，录进去的是 F19，而 F19 在按住 Hyper 的整个过程里都是按下状态，于是切 app 也会触发对方的功能。上面那个按钮就是为这一步准备的——它把 Caps Lock 临时变回真正的 F18，录完自动变回来。

                有些录制框只收修饰键，一个键码都不肯存（豆包输入法的免按模式就是），F18 在那里录不进去。这种就选「发送 ⌃⌘」，到对方那儿把这两个键真按一遍录进去即可，不用借 20 秒。

                挑 ⌃⌘ 不是随手挑的：按住 Caps Lock 的整个过程（⌥ → ⌃⌥ → ⌃⌥⇧ → ⌃⌥⇧⌘，松开时反序）从头到尾都不会出现 ⌃⌘ 这个组合，所以切 app 不可能误触发它。
                """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("版本") {
                    HStack(spacing: 10) {
                        Text(model.version).monospacedDigit().foregroundStyle(.secondary)
                        Button("检查更新") { model.checkForUpdates() }
                    }
                }
                if let status = model.updateStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if !model.inApplicationsFolder {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Hyper 不在「应用程序」文件夹里，自动更新无法工作。请把 Hyper.app 拖进「应用程序」后重新打开。")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                Text("每天自动检查一次，也可以随时手动检查。更新会校验签名与当前版本一致后才安装。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("记录按键调试日志", isOn: bind(\.debug))
            } footer: {
                Text("只记录键码，不记录字符。排查「按了没反应」时才需要打开。\nlog stream --level debug --predicate 'subsystem == \"com.indincys.hyper\"'")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.save() }
        )
    }
}
