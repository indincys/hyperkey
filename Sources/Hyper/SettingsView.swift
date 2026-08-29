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
        .frame(width: 720, height: 640)
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
    @State private var showingTemplates = false
    @State private var showingCreateProfile = false
    @State private var showingRenameProfile = false
    @State private var showingDeleteConfirmation = false
    @State private var showingImportRecoveryConfirmation = false
    @State private var showingDowngradeRecoveryConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(model: model)
            Divider()

            ProfileToolbar(
                model: model,
                showingTemplates: $showingTemplates,
                showingCreate: $showingCreateProfile,
                showingRename: $showingRenameProfile,
                showingDeleteConfirmation: $showingDeleteConfirmation,
                showingImportRecoveryConfirmation: $showingImportRecoveryConfirmation,
                showingDowngradeRecoveryConfirmation: $showingDowngradeRecoveryConfirmation
            )
            Divider()

            if let notice = model.profileNotice {
                HStack(spacing: 7) {
                    if model.isImportingProfiles {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                    }
                    Text(notice).lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.07))
                .accessibilityElement(children: .combine)
            }

            if model.rows.isEmpty {
                EmptyState { model.isPickingApp = true }
            } else {
                List {
                    ForEach(model.rows) { row in
                        BindingRowView(
                            row: row,
                            conflicts: model.conflicts(for: row),
                            onKeyChange: { model.setKey($0, for: row) },
                            onRemove: { model.remove(row) },
                            onRepair: { model.repair($0) }
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

                if !model.shortcutConflicts.isEmpty {
                    Label("\(model.shortcutConflicts.count) 个冲突待处理", systemImage: "exclamationmark.triangle.fill")
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
            AppPickerSheet(
                model: model,
                source: \.catalog,
                picked: \.boundTargets,
                isPresented: $model.isPickingApp,
                onPick: { model.add($0) },
                onFinder: { model.addFromFinder() }
            )
        }
        .sheet(isPresented: $showingTemplates) {
            TemplateGallery(model: model, isPresented: $showingTemplates)
        }
        .sheet(isPresented: $showingCreateProfile) {
            ProfileNameSheet(
                title: "新建 Profile",
                initialName: "Profile \(model.profiles.count + 1)",
                confirmTitle: "创建",
                isPresented: $showingCreateProfile
            ) { model.createProfile(named: $0, copyingActive: false) }
        }
        .sheet(isPresented: $showingRenameProfile) {
            ProfileNameSheet(
                title: "重命名 Profile",
                initialName: model.activeProfileName,
                confirmTitle: "重命名",
                isPresented: $showingRenameProfile
            ) { model.renameActiveProfile(to: $0) }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingProfileImport != nil },
            set: { if !$0 { model.cancelPendingProfileImport() } }
        )) {
            if let preview = model.pendingProfileImport {
                ProfileImportPreviewSheet(model: model, preview: preview)
            }
        }
        .confirmationDialog(
            "删除“\(model.activeProfileName)”？",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("删除 Profile", role: .destructive) { model.deleteActiveProfile() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("其中的快捷键会被删除；其他 Profiles 不受影响。")
        }
        .confirmationDialog(
            "恢复导入前的 Profiles？",
            isPresented: $showingImportRecoveryConfirmation
        ) {
            Button("恢复") { model.restoreImportRecovery() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前 Profiles 会被替换；其他设置不受影响。")
        }
        .confirmationDialog(
            "从兼容快照恢复 Profiles？",
            isPresented: $showingDowngradeRecoveryConfirmation
        ) {
            Button("恢复") { model.restoreDowngradeRecovery() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("用于找回被旧版 Hyper 覆盖的非当前 Profiles。")
        }
    }
}

private struct ProfileToolbar: View {
    @ObservedObject var model: SettingsModel
    @Binding var showingTemplates: Bool
    @Binding var showingCreate: Bool
    @Binding var showingRename: Bool
    @Binding var showingDeleteConfirmation: Bool
    @Binding var showingImportRecoveryConfirmation: Bool
    @Binding var showingDowngradeRecoveryConfirmation: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker("当前 Profile", selection: Binding(
                get: { model.activeProfileID },
                set: { if let id = $0 { model.switchProfile(to: id) } }
            )) {
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 210)
            .accessibilityLabel("当前快捷键 Profile")

            Button {
                showingCreate = true
            } label: {
                Image(systemName: "plus")
            }
            .help("新建空白 Profile")
            .accessibilityLabel("新建 Profile")

            Menu {
                Button("复制当前 Profile") { model.duplicateActiveProfile() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("重命名…") { showingRename = true }
                Divider()
                Button("删除…", role: .destructive) { showingDeleteConfirmation = true }
                    .disabled(model.profiles.count <= 1)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("复制、重命名或删除当前 Profile")
            .accessibilityLabel("管理当前 Profile")

            Spacer()

            Button {
                showingTemplates = true
            } label: {
                Label("场景模板", systemImage: "square.grid.2x2")
            }
            .help("预览 Work、Communication 和 Creator 模板；导入不会覆盖现有按键")

            Menu {
                Button("导出全部 Profiles…") { model.exportProfiles() }
                Button("导入并替换 Profiles…") { model.importProfiles() }
                    .disabled(model.isImportingProfiles)
                if model.hasImportRecovery || model.hasDowngradeRecovery {
                    Divider()
                }
                if model.hasImportRecovery {
                    Button("恢复上次导入前的 Profiles…") {
                        showingImportRecoveryConfirmation = true
                    }
                }
                if model.hasDowngradeRecovery {
                    Button("从旧版兼容快照恢复…") {
                        showingDowngradeRecoveryConfirmation = true
                    }
                }
            } label: {
                Label("导入 / 导出", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct ProfileImportPreviewSheet: View {
    @ObservedObject var model: SettingsModel
    let preview: ProfileImportPreview

    private var incomingProfileCount: Int { preview.profiles.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入前预览").font(.title3.weight(.semibold))
                    Text("文件已通过结构、数量、长度与 4 MB 上限验证")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                importMetric("Profiles", "\(preview.currentProfileCount) → \(incomingProfileCount)")
                importMetric("快捷键", "\(preview.currentBindingCount) → \(preview.incomingBindingCount)")
                importMetric("当前 Profile", preview.profiles.first {
                    $0.id == preview.activeProfileID
                }?.name ?? "—")
            }

            GroupBox("差异摘要") {
                VStack(alignment: .leading, spacing: 8) {
                    differenceRow("新增", names: preview.addedNames, color: .green)
                    differenceRow("更改", names: preview.changedNames, color: .orange)
                    differenceRow("移除", names: preview.removedNames, color: .red)
                    if preview.addedNames.isEmpty && preview.changedNames.isEmpty
                        && preview.removedNames.isEmpty {
                        Label("内容与当前 Profiles 一致", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .foregroundStyle(.blue)
                Text("确认后会先创建自动恢复点，再原子替换快捷键 Profiles。剪贴板、隐私和通用设置不会被导入文件覆盖。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("取消") { model.cancelPendingProfileImport() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("创建恢复点并替换") { model.commitPendingProfileImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .accessibilityElement(children: .contain)
    }

    private func importMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func differenceRow(_ label: String, names: [String], color: Color) -> some View {
        if !names.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
                    .frame(width: 36, alignment: .leading)
                Text(names.joined(separator: "、"))
                    .font(.callout).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ProfileNameSheet: View {
    let title: String
    let initialName: String
    let confirmTitle: String
    @Binding var isPresented: Bool
    let onConfirm: (String) -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Profile 名称", text: $name)
                .focused($focused)
                .accessibilityLabel("Profile 名称")
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onConfirm(name)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = initialName
            focused = true
        }
    }
}

private struct TemplateGallery: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool
    @State private var selectedID = ShortcutProfileTemplate.builtIns[0].id

    private var selected: ShortcutProfileTemplate {
        ShortcutProfileTemplate.builtIns.first { $0.id == selectedID }
            ?? ShortcutProfileTemplate.builtIns[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            List(ShortcutProfileTemplate.builtIns, selection: $selectedID) { template in
                Label(template.name, systemImage: template.symbolName).tag(template.id)
            }
            .frame(width: 190)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Label(selected.name, systemImage: selected.symbolName)
                    .font(.title2.weight(.semibold))
                Text(selected.summary).foregroundStyle(.secondary)
                Text("导入到“\(model.activeProfileName)”")
                    .font(.callout.weight(.medium))

                List(selected.profile.allBindings) { binding in
                    HStack {
                        Text("⇪ + \(Keys.display(forName: binding.key))")
                            .frame(width: 100, alignment: .leading)
                            .font(.body.monospaced())
                        Text(BuiltinAction(rawValue: binding.target)?.displayName ?? binding.target)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Hyper 加 \(Keys.display(forName: binding.key))，\(BuiltinAction(rawValue: binding.target)?.displayName ?? binding.target)"
                    )
                }

                Text("已有按键和已有目标始终保留；冲突项会跳过，不会覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("关闭") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("安全导入") {
                        model.importTemplate(selected)
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 470)
        }
        .frame(height: 460)
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
    let conflicts: [ShortcutConflict]
    let onKeyChange: (String) -> Void
    let onRemove: () -> Void
    let onRepair: (ShortcutConflict) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: conflicts.isEmpty ? 0 : 7) {
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
                isDuplicate: conflicts.contains { $0.kind == .duplicateKey },
                onCapture: onKeyChange
            )
            .frame(width: 72, height: 28)
            .accessibilityLabel("\(row.displayName) 的快捷键，当前为 \(Keys.display(forName: row.key))")
            .accessibilityHint("按下空格开始录制，再按想使用的按键；Escape 取消")

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(hovering ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
            .help("删除这个快捷键")
            .accessibilityLabel("删除 \(row.displayName) 快捷键")
            }

            ForEach(conflicts) { conflict in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(conflict.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(conflict.kind == .missingApplication ? "移除" : "修复") {
                        onRepair(conflict)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .accessibilityLabel("修复 \(row.displayName) 的冲突")
                }
                .padding(.leading, 42)
            }
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

/// One sheet for both lists: the shortcuts tab binds a key to whatever is picked, the
/// clipboard tab excludes it from capture. Only the source list, which rows already
/// count as picked, and the two callbacks differ.
///
/// The list and the marks are read through key paths rather than handed over as values:
/// the catalog finishes scanning while this is already on screen, and the marks change
/// with every pick.
private struct AppPickerSheet: View {
    @ObservedObject var model: SettingsModel
    let source: KeyPath<SettingsModel, [InstalledApp]>
    let picked: KeyPath<SettingsModel, Set<String>>
    @Binding var isPresented: Bool
    let onPick: (InstalledApp) -> Void
    let onFinder: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [InstalledApp] {
        let apps = model[keyPath: source]
        guard !query.isEmpty else { return apps }
        return apps.filter {
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

            // The scan populates the whole catalog at once, so an empty one means it is
            // still running rather than "nothing matched".
            if model.catalog.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                List(results) { app in
                    AppPickerRow(app: app, alreadyBound: model[keyPath: picked].contains(app.target))
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
                    // The open panel goes up after this sheet is gone, not on top of it.
                    isPresented = false
                    DispatchQueue.main.async { onFinder() }
                }
                Spacer()
                Button("完成") { isPresented = false }
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

    /// Picking leaves the sheet open, so several applications can be added in one go.
    private func add(_ app: InstalledApp) {
        onPick(app)
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
                    IgnoredAppsBlock(model: model)
                } header: {
                    Text("记什么")
                } footer: {
                    Text("1Password、钥匙串这类工具会给复制出来的密码打一个「机密」标记，打开这个开关就不会记录它们。建议保持打开。\n被忽略的应用里复制的任何内容都不会记录，不管对方有没有打标记——适合放密码管理器、笔记里的私密库这类隐私敏感工具。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("识别出敏感内容后", selection: bind(\.sensitiveHandling)) {
                        ForEach(SensitiveClipboardHandling.allCases, id: \.rawValue) { handling in
                            Text(handling.label).tag(handling)
                        }
                    }
                    if model.sensitiveHandling != .skip {
                        Stepper(value: bind(\.sensitiveTTLMinutes), in: 1...(24 * 60)) {
                            LabeledContent("最长保留") {
                                if model.sensitiveTTLMinutes < 60 {
                                    Text("\(model.sensitiveTTLMinutes) 分钟").monospacedDigit()
                                } else {
                                    Text("\(model.sensitiveTTLMinutes / 60) 小时 \(model.sensitiveTTLMinutes % 60) 分")
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    Text(model.sensitiveHandling.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("当前敏感内容策略：\(model.sensitiveHandling.explanation)")
                } header: {
                    Text("敏感内容保护")
                } footer: {
                    Text("自动跳过或删除只采用可证明的规则：系统机密/临时标记、带严格短语和 4–8 位完整数字边界的验证码，以及标准私钥边界。像密码的高熵字符串只加风险标记，绝不自动跳过或删除，避免误伤 URL、版本号、构建标识和代码。到期删除时收藏不能阻止。系统标记为机密的内容默认始终不保存；关闭上面的保护开关属于高风险操作。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if let until = model.activeClipboardPauseUntil {
                        Label {
                            Text("已暂停，到 \(until, format: .dateTime.hour().minute()) 自动恢复")
                        } icon: {
                            Image(systemName: "eye.slash.fill")
                        }
                        .foregroundStyle(.orange)
                        Button("立即恢复记录") { model.resumeClipboardCapture() }
                    } else {
                        HStack {
                            Button("暂停 15 分钟") { model.pauseClipboard(minutes: 15) }
                            Button("暂停 1 小时") { model.pauseClipboard(minutes: 60) }
                        }
                        Stepper(
                            value: $model.customClipboardPauseMinutes,
                            in: 1...(24 * 60), step: 5
                        ) {
                            LabeledContent("自定义") {
                                Text("\(model.customClipboardPauseMinutes) 分钟")
                                    .monospacedDigit()
                            }
                        }
                        Button("按自定义时长暂停") {
                            model.pauseClipboard(minutes: model.customClipboardPauseMinutes)
                        }
                    }
                } header: {
                    Text("临时隐私模式")
                } footer: {
                    Text("暂停期间不会读取或保存任何新剪贴板内容。恢复时会把当前剪贴板设为新基线，因此暂停期间复制过的内容不会被补录。已有历史仍可查找和粘贴。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("面板大小", selection: bind(\.panelSize)) {
                        ForEach(ClipPanelSize.allCases, id: \.rawValue) {
                            Text($0.label).tag($0.rawValue)
                        }
                    }
                    Picker("打开位置", selection: bind(\.panelPosition)) {
                        ForEach(ClipPanelPosition.allCases, id: \.rawValue) {
                            Text($0.label).tag($0.rawValue)
                        }
                    }
                } header: {
                    Text("面板")
                } footer: {
                    Text("不管选哪个位置，面板始终打开在鼠标所在的那块屏幕上。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("粘贴后把原来的剪贴板内容还原回去", isOn: bind(\.restoreAfterPaste))
                    Picker("按 ↩ 时", selection: bind(\.returnAction)) {
                        ForEach(ClipReturnAction.allCases, id: \.rawValue) {
                            Text($0.label).tag($0.rawValue)
                        }
                    }
                    Picker("合并粘贴时的分隔符", selection: Binding(
                        get: { model.joinSeparator },
                        set: { model.joinSeparator = $0; model.save() }
                    )) {
                        ForEach(separators, id: \.value) { Text($0.label).tag($0.value) }
                    }
                } header: {
                    Text("粘贴")
                } footer: {
                    Text("关掉「还原」时，粘完之后剪贴板里就是你刚粘的东西——再按一次 ⌘V 还是它。\n选了「仅复制」之后两个动作对调：↩ 只复制并关闭面板，⌘↩ 变成直接粘贴。\n在面板里 ⌥ 点选多条，按 ↩ 就会用这个分隔符把它们连成一段粘出去。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("现在存了") {
                        Text("\(model.clipboardCount) 条 · 收藏 \(model.pinnedCount) 条")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    ClipKindBreakdown(model: model)
                    DiskUsageBreakdown(model: model)
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
                    HStack {
                        Button("清理孤儿文件") { model.cleanOrphanFiles() }
                        if model.didCleanOrphans {
                            Label("已清理", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        }
                        Spacer()
                    }
                    .animation(.easeInOut(duration: 0.15), value: model.didCleanOrphans)
                } footer: {
                    Text("存在 ~/.local/share/hyper/clipboard/，纯本地，不上传任何地方。\n「清理孤儿文件」删掉那些已经没有记录指向的载荷、缩略图和索引文件——正常情况下不会有，崩溃或者手动删过文件之后可能留下几个。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshClipboardStats() }
        .sheet(isPresented: $model.isPickingIgnoredApp) {
            AppPickerSheet(
                model: model,
                source: \.ignorableCatalog,
                picked: \.ignoredAppIDs,
                isPresented: $model.isPickingIgnoredApp,
                onPick: { model.addIgnoredApp($0.target) },
                onFinder: { model.addIgnoredAppFromFinder() }
            )
        }
    }

    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.save() }
        )
    }
}

/// What the history is made of, as one proportional bar plus a legend.
///
/// A bar rather than a list of numbers because the useful question here is "what is
/// filling this up" — a glance at a mostly-orange bar answers it, and the legend is
/// there for the exact counts.
private struct ClipKindBreakdown: View {
    @ObservedObject var model: SettingsModel

    /// Fixed hues rather than the accent color: the whole point is telling six
    /// categories apart, which one tinted color cannot do. Kept desaturated enough to
    /// sit inside a settings form without shouting.
    static func color(for kind: ClipKind) -> Color {
        switch kind {
        case .text: return .blue
        case .richText: return .purple
        case .url: return .teal
        case .image: return .orange
        case .files: return .green
        case .color: return .pink
        }
    }

    var body: some View {
        let breakdown = model.kindBreakdown
        VStack(alignment: .leading, spacing: 8) {
            if breakdown.isEmpty {
                Text("还没有记录任何内容")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProportionBar(segments: breakdown)
                // Adaptive, so the legend reflows instead of clipping when the window
                // is narrow or the user runs a larger text size.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(breakdown, id: \.kind) { entry in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Self.color(for: entry.kind))
                                .frame(width: 7, height: 7)
                            Text(entry.kind.label)
                                .font(.caption)
                            Text("\(entry.count)")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One horizontal bar split by count. Widths are computed against the measured width
/// rather than handed to a stack as weights, because SwiftUI has no proportional layout
/// primitive — and a rounded-up minimum keeps a single-entry kind from vanishing.
private struct ProportionBar: View {
    let segments: [(kind: ClipKind, count: Int)]

    private let spacing: CGFloat = 1
    private let minimumWidth: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let total = CGFloat(segments.reduce(0) { $0 + $1.count })
            let available = max(
                0, geometry.size.width - spacing * CGFloat(max(0, segments.count - 1))
            )
            HStack(spacing: spacing) {
                ForEach(segments, id: \.kind) { entry in
                    Rectangle()
                        .fill(ClipKindBreakdown.color(for: entry.kind))
                        .frame(width: width(for: entry.count, total: total, available: available))
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func width(for count: Int, total: CGFloat, available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return max(minimumWidth, available * CGFloat(count) / total)
    }
}

/// Total on disk, then the three directories it is made of.
private struct DiskUsageBreakdown: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 4) {
            LabeledContent("磁盘占用") {
                Text(model.diskUsage).monospacedDigit()
            }
            row("载荷", model.payloadUsage)
            row("缩略图", model.thumbnailUsage)
            row("搜索索引", model.searchUsage)
        }
        .padding(.vertical, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 12)
            Spacer()
            Text(value)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// The per-application exclusion list, living inside the「记什么」section.
private struct IgnoredAppsBlock: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("忽略这些应用")
                Spacer()
                Button("添加应用…") { model.isPickingIgnoredApp = true }
                    .controlSize(.small)
            }

            if model.ignoredAppRows.isEmpty {
                Text("没有忽略任何应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.ignoredAppRows) { row in
                    IgnoredAppRowView(row: row) { model.removeIgnoredApp(row.bundleID) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct IgnoredAppRowView: View {
    let row: IgnoredAppRow
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "questionmark.app.dashed")
                        .resizable().scaledToFit()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)

            Text(row.displayName)
                .font(.callout)
                .lineLimit(1)
                .help(row.bundleID)

            Spacer(minLength: 8)

            Button("移除", action: onRemove)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                Picker("应用快捷键行为", selection: bind(\.repeatPressRaw)) {
                    Text("按一次显示，再按一次隐藏").tag(RepeatPress.hide.rawValue)
                    Text("按住查看，松开返回").tag(RepeatPress.peek.rawValue)
                    Text("重复按时循环窗口").tag(RepeatPress.cycle.rawValue)
                    Text("只打开应用").tag(RepeatPress.none.rawValue)
                }
            } footer: {
                Text("""
                选「按住查看，松开返回」，按住 Caps Lock 和应用字母时会切到该应用；松开字母或 Caps Lock 就隐藏它并回到刚才的应用，适合快速瞄一眼状态。

                选「按一次显示，再按一次隐藏」，目标应用不在前台时会显示并激活它；已经在前台时会隐藏整个应用，由 macOS 显示最近使用的应用。这与 Raycast 的 Toggle Visibility 行为一致。

                选「重复按时循环窗口」，连按会在这个应用自己的窗口之间轮流切换——适合一个应用开好几个窗口的情况，比如浏览器的多个窗口、编辑器的多个项目。最小化的窗口和面板不参与，只有一个窗口时按了也不动。
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
