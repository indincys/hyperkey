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
                if let icon = row.icon {
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
                if row.missing {
                    Text("找不到这个应用")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(row.target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    private var tapActionSelection: String {
        switch model.tapActionRaw {
        case "none", "": return "none"
        case "escape", "esc": return "escape"
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
                Toggle("目标应用已在最前时，再按一次隐藏它", isOn: bind(\.toggleHideIfFrontmost))
            } footer: {
                Text("打开后，按住 Caps Lock 连按同一个键就能在「看一眼」和「切回去」之间来回切换。")
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
            } footer: {
                Text("「单击」指按下 Caps Lock 后没有按别的键就松开。按住不放始终是 Hyper。")
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
