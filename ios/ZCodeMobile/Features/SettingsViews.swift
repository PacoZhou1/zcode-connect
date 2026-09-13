import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var body: some View {
        Group {
            if embedded { settingsForm }
            else { NavigationStack { settingsForm } }
        }
    }
    private var settingsForm: some View {
        @Bindable var store = store
        return Form {
            Section("外观") {
                Picker("颜色", selection: $store.appearance) {
                    ForEach(["跟随系统", "浅色", "深色"], id: \.self) { Text($0) }
                }
                NavigationLink {
                    ThemeColorSettingsView()
                } label: {
                    HStack {
                        Text("主题色")
                        Spacer()
                        Circle().fill(ZTheme.accent).frame(width: 20, height: 20)
                        Text(ThemePreferences.shared.selection.label).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("settings.theme")
                Toggle("触感反馈", isOn: $store.hapticsEnabled)
                Toggle("显示时间", isOn: $store.showTimestamps)
            }
            Section("连接") {
                LabeledContent("电脑", value: store.hostName)
                LabeledContent("状态", value: store.connection.label)
                if let version = store.bridgeVersion { LabeledContent("ZCode 版本", value: version) }
                ForEach(store.profiles) { profile in
                    NavigationLink(profile.name) { ConnectionDetailView(profile: profile) }
                }
                NavigationLink { PairingView(embedded: true) } label: { Label("添加连接", systemImage: "plus") }
            }
            Section("关于") {
                LabeledContent("ZCode Mobile", value: "1.0")
                Text("使用原生 SwiftUI 与 Apple Liquid Glass 构建。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !store.isReferenceMode {
                    Button("体验参考界面") { store.enterReferenceMode(); dismiss() }
                } else {
                    Button("退出界面体验") { store.leaveReferenceMode(); dismiss() }
                }
            }
        }
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onChange(of: store.appearance) { store.savePreferences() }
        .onChange(of: store.hapticsEnabled) { store.savePreferences() }
        .onChange(of: store.showTimestamps) { store.savePreferences() }
    }
}

struct ConnectionDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let profile: ConnectionProfile
    @State private var confirmRemoval = false
    @State private var confirmRelayReconnect = false
    var body: some View {
        Form {
            Section {
                LabeledContent("名称", value: profile.name)
                LabeledContent("地址", value: profile.baseURL)
            }
            Section {
                Button("重新连接") {
                    if profile.isRelay { confirmRelayReconnect = true }
                    else { Task { await store.connect(profile) } }
                }.disabled(store.connection == .connecting)
                Button("移除连接", role: .destructive) { confirmRemoval = true }
            }
        }.navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("连接这台电脑？", isPresented: $confirmRelayReconnect, titleVisibility: .visible) {
                Button("连接并使用此手机控制") {
                    Task { await store.connect(profile, confirmedControllerReplacement: true) }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("如果另一台手机正在控制这台电脑，此次连接可能替换它。电脑上的任务会保留。") }
            .confirmationDialog("移除这台电脑的连接？", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("移除连接", role: .destructive) { store.removeConnection(profile); dismiss() }
            } message: { Text("设备上的连接密钥也会被移除，电脑里的任务不会删除。") }
    }
}

struct AdvancedSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var busy = false
    private var sessionID: String? { store.currentSessionID }
    private var selection: ModelSelection? {
        sessionID.flatMap { store.modelSelections[$0] } ?? store.effectiveNewModelSelection
    }
    private var currentModel: RemoteModel? {
        store.models.first { $0.providerId == selection?.providerId && $0.modelId == selection?.modelId }
    }
    private var canEdit: Bool {
        !busy && (sessionID == nil || store.remoteSettings[sessionID!]?.mutable == true)
    }
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("高级").font(.system(size: 17, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }.padding(.top, 32).padding(.bottom, 22.8).measureLayout("advanced.header")
            VStack(spacing: 0) {
                if store.isReferenceMode {
                    Menu {
                        Picker("模型", selection: $store.options.model) {
                            ForEach(["6 Astra", "5.6 Sol", "5.6 Terra", "5.6 Luna"], id: \.self) { Text($0).tag($0) }
                        }
                    } label: { settingRow("模型", value: store.options.model) }
                } else {
                    Menu {
                        ForEach(store.models) { model in
                            Button {
                                apply(model: ModelSelection(providerId: model.providerId, modelId: model.modelId,
                                    thoughtLevel: model.thoughtLevels.contains(selection?.thoughtLevel ?? "")
                                        ? selection?.thoughtLevel : model.defaultThoughtLevel))
                            } label: {
                                if let reason = model.unavailableReason, !model.available {
                                    Label("\(model.name) · \(model.providerName) · \(reason == "provider_disabled" ? "未启用" : "暂不可用")", systemImage: "exclamationmark.circle")
                                } else if model.id == currentModel?.id {
                                    Label("\(model.name) · \(model.providerName)", systemImage: "checkmark")
                                } else { Text("\(model.name) · \(model.providerName)") }
                            }.disabled(!model.available)
                        }
                    } label: {
                        settingRow("模型", value: currentModel?.name ?? selection?.modelId ?? "沿用电脑配置")
                    }
                    .disabled(!canEdit || store.models.isEmpty)
                    .accessibilityIdentifier("advanced.model")
                }
                Divider()
                if store.isReferenceMode {
                    Menu {
                        Picker("智能", selection: $store.options.reasoning) {
                            ForEach(ReasoningLevel.allCases) { level in Text(level.label).tag(level) }
                        }
                    } label: { settingRow("智能", value: store.options.reasoning.label) }
                } else {
                    Menu {
                        ForEach(currentModel?.thoughtLevels ?? [], id: \.self) { level in
                            Button { apply(reasoning: level) } label: {
                                let label = ReasoningLevel(wireValue: level)?.label ?? level
                                if level == selection?.thoughtLevel { Label(label, systemImage: "checkmark") }
                                else { Text(label) }
                            }
                        }
                    } label: {
                        settingRow("智能", value: selection?.thoughtLevel.map { ReasoningLevel(wireValue: $0)?.label ?? $0 } ?? "沿用电脑配置")
                    }
                    .disabled(!canEdit || (currentModel?.thoughtLevels.isEmpty ?? true))
                    .accessibilityIdentifier("advanced.reasoning")
                }
            }.padding(.horizontal, 20)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 25))
                .measureLayout("advanced.modelCard").padding(.bottom, 35.7)
            Group {
                if store.isReferenceMode {
                    Menu {
                        Picker("速度", selection: $store.options.speed) {
                            Text("标准").tag("标准")
                            Text("快速").tag("快速")
                        }
                    } label: { settingRow("速度", value: store.options.speed) }
                } else {
                    HStack { Text("速度"); Spacer(); Text("由电脑决定").foregroundStyle(.secondary) }.frame(minHeight: 52)
                }
            }.padding(.horizontal, 20).background(.quaternary.opacity(0.7), in: Capsule()).measureLayout("advanced.speedCard")
            if busy { ProgressView("正在更新任务设置…").font(.footnote) }
            else if !store.isReferenceMode {
                Text(sessionID != nil && !canEdit ? "任务运行期间无法修改模型；停止或完成后可以调整。" : "选择只应用于当前任务，不会改动电脑的默认设置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 17.6)).tint(.primary)
        .padding(.horizontal, 20)
        .presentationDetents([.fraction(0.561), .large])
        .presentationDragIndicator(.visible)
        .measureLayout("advanced.sheet")
        .task { if let sessionID { await store.loadSettings(sessionID) } }
    }
    private func settingRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 18)
            Text(value).foregroundStyle(Color.primary).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 14)).foregroundStyle(Color.primary)
        }.frame(minHeight: 52).contentShape(Rectangle())
    }
    private func apply(model: ModelSelection? = nil, reasoning: String? = nil) {
        let id = sessionID
        busy = true
        Task {
            _ = await store.updateSettings(id, model: model, reasoning: reasoning)
            busy = false
        }
    }
}

struct PermissionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: String?
    @State private var busy = false
    @State private var confirmFullAccess = false
    @State private var showHelp = false
    private var currentPermission: PermissionMode { store.permission(for: sessionID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(store.isReferenceMode ? "应如何批准 Codex 操作？" : "应如何批准 ZCode 操作？")
                Button { showHelp = true } label: { Text("了解更多").underline() }
            }.font(.system(size: 15)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
              ForEach(PermissionMode.allCases) { mode in
                Button {
                    if mode == .full && !store.isReferenceMode { confirmFullAccess = true }
                    else { apply(mode) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: mode.symbol).font(.system(size: 20)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode == .custom && store.isReferenceMode ? "自定义 (config.toml)" : mode.title).font(.system(size: 15))
                            Text(mode == .custom ? (store.isReferenceMode ? "使用 config.toml 中定义的权限" : "当前连接尚不支持编辑自定义规则") : mode.detail)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineSpacing(4.0 / 3.0).fixedSize(horizontal: false, vertical: true)
                        }.padding(.trailing, 8)
                        Spacer(minLength: 2)
                        if currentPermission == mode {
                            Image(systemName: "checkmark").font(.system(size: 18)).frame(width: 20)
                        } else { Color.clear.frame(width: 20, height: 1) }
                    }.contentShape(Rectangle().inset(by: -5))
                }.buttonStyle(.plain).disabled(busy || (!store.isReferenceMode && mode == .custom))
                    .accessibilityIdentifier("permission.\(mode.rawValue)")
                    .accessibilityAddTraits(currentPermission == mode ? .isSelected : [])
                    .accessibilityRemoveTraits(currentPermission != mode ? .isSelected : [])
              }
            }
            if busy { ProgressView("正在更新权限…").font(.footnote) }
        }.padding(.horizontal, 18).padding(.vertical, 14).frame(width: 320).tint(.primary)
            .measureLayout("permissions.popover")
            .alert("操作权限", isPresented: $showHelp) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("请求批准：主机遇到需要许可的操作时，由你决定。替我批准：允许主机按自动编辑策略处理操作。完全访问：主机可直接执行操作。实际规则和可用项以当前主机为准。")
            }
            .task { if let sessionID { await store.loadSettings(sessionID) } }
            .confirmationDialog("允许此任务完全访问电脑？", isPresented: $confirmFullAccess, titleVisibility: .visible) {
                Button("允许完全访问", role: .destructive) { apply(.full, confirmed: true) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("ZCode 可以直接编辑文件和运行命令，不再逐次请求批准。只对当前任务生效。")
            }
    }
    private func apply(_ mode: PermissionMode, confirmed: Bool = false) {
        busy = true
        Task {
            if store.isReferenceMode {
                store.options.permission = mode
                store.haptic()
                dismiss()
            } else if await store.updateSettings(sessionID, permissionMode: mode.wireValue, confirmFullAccess: confirmed) {
                store.haptic()
                dismiss()
            }
            busy = false
        }
    }
}

struct ThemeColorSettingsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List {
            Section {
                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        ThemePreferences.shared.selection = theme
                        store.haptic()
                    } label: {
                        HStack(spacing: 14) {
                            Circle().fill(theme.color).frame(width: 26, height: 26)
                            Text(theme.label).foregroundStyle(.primary)
                            Spacer()
                            if ThemePreferences.shared.selection == theme {
                                Image(systemName: "checkmark").foregroundStyle(theme.color)
                            }
                        }.frame(minHeight: 32).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("theme." + theme.rawValue)
                    .accessibilityAddTraits(ThemePreferences.shared.selection == theme ? .isSelected : [])
                }
            } footer: {
                Text("应用于按钮、图标与对话气泡，所有电脑共用此设置。")
            }
            Section("预览") {
                HStack {
                    Spacer()
                    Text("从这里继续你的工作。")
                        .foregroundStyle(ZTheme.userText).padding(14)
                        .background(ZTheme.userBubble, in: RoundedRectangle(cornerRadius: 20))
                }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("主题色").navigationBarTitleDisplayMode(.inline)
    }
}
