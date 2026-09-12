import SwiftUI
import VisionKit
import AVFoundation

struct ConnectionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var relayReconnect: ConnectionProfile?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("远程", systemImage: "laptopcomputer").font(.headline)
                    Text("随时查看电脑上的任务，继续你的工作。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("我的电脑") {
                    ForEach(store.profiles) { profile in
                        Button {
                            if profile.isRelay && !(store.activeProfile == profile && store.connection.isOnline && !store.isReferenceMode) { relayReconnect = profile }
                            else { dismiss(); Task { await store.switchComputer(profile) } }
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                VStack(alignment: .leading) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.isRelay ? "ZCode 远程 · \(profile.relayWorkspaceKey?.split(separator: "/").last.map(String.init) ?? "项目")" : profile.baseURL).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == store.activeProfileID {
                                    Circle().fill(store.connection.isOnline ? .green : .gray).frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                    NavigationLink { PairingView(embedded: true) } label: {
                        Label("添加连接", systemImage: "plus")
                    }
                }
                Section {
                    Button { store.showArchived = false; store.path = []; dismiss() } label: {
                        Label("全部任务", systemImage: "bubble.left.and.bubble.right")
                    }
                    Button { store.showArchived = true; store.path = []; dismiss() } label: {
                        Label("已归档任务", systemImage: "archivebox")
                    }
                    NavigationLink { SettingsView(embedded: true) } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
                if store.isReferenceMode {
                    Section {
                        Button("退出界面体验") { store.leaveReferenceMode(); dismiss() }
                    } footer: { Text("界面体验使用本机内置的参考内容。") }
                }
            }
            .navigationTitle("连接").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
        .confirmationDialog("连接这台电脑？", isPresented: Binding(get: { relayReconnect != nil }, set: { if !$0 { relayReconnect = nil } }), titleVisibility: .visible) {
            Button("连接并使用此手机控制") {
                guard let profile = relayReconnect else { return }
                relayReconnect = nil; dismiss()
                Task { await store.switchComputer(profile, confirmedControllerReplacement: true) }
            }
            Button("取消", role: .cancel) { relayReconnect = nil }
        } message: { Text("如果另一台手机正在控制这台电脑，此次连接可能替换它。电脑上的任务会保留。") }
    }
}

struct PairingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onboarding = false
    @State private var manualConnection = false
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var certificateSHA256 = ""
    @State private var connecting = false
    @State private var scanner = false
    @State private var failure: String?
    @State private var relayPayload: String?
    @State private var confirmRelay = false
    @State private var choosingWorkspace = false
    @State private var beganRelay = false
    @State private var relayAttempt = UUID()

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .confirmationDialog("连接这台电脑？", isPresented: $confirmRelay, titleVisibility: .visible) {
            Button("连接并使用此手机控制") { Task { await connectRelay() } }
            Button("取消", role: .cancel) {}
        } message: { Text("连接 ZCode 远程可能替换另一台手机的控制连接。确认后将读取电脑上的项目，由你选择要打开的项目。") }
        .onDisappear { if beganRelay && !store.connection.isOnline { store.cancelRelayPairing(attempt: relayAttempt) } }
        .sheet(isPresented: $scanner) {
            QRScanner { payload in
                scanner = false
                parse(payload)
            }
        }
    }
    private var content: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 42, weight: .light))
                        .foregroundStyle(ZTheme.accent).padding(.vertical, 8)
                    Text("连接你的电脑").font(.title2.weight(.semibold))
                    Text(onboarding ? "先连接一台电脑，再查看和继续你的任务。电脑需要保持运行和联网。" : "在电脑的 ZCode 左下角点击手机图标，开启远程控制，然后扫描或粘贴连接链接。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
            }
            Section {
                Button { scanner = true } label: {
                    Label("扫描连接二维码", systemImage: "qrcode.viewfinder")
                }.disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)
                Button {
                    if let value = UIPasteboard.general.string { parse(value) }
                } label: { Label("粘贴连接信息", systemImage: "doc.on.clipboard") }
            }
            if onboarding, !store.profiles.isEmpty {
                Section {
                    Button("选择已添加的电脑", systemImage: "laptopcomputer") { store.sheet = .connections }
                }
            }
            if choosingWorkspace {
                Section("选择电脑上的项目") {
                    ForEach(store.relayWorkspaces) { workspace in
                        Button {
                            Task { await chooseWorkspace(workspace) }
                        } label: {
                            HStack {
                                Image(systemName: workspace.kind == "remote" ? "network" : "folder")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workspace.workspacePath.split(separator: "/").last.map(String.init) ?? workspace.workspacePath)
                                    Text(workspace.workspacePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }.disabled(connecting || !workspace.canAttach)
                    }
                    if store.relayWorkspaces.isEmpty { Text("电脑尚未打开项目，请先在 ZCode 中打开一个项目。") }
                    Button {
                        connecting = true
                        failure = nil
                        Task {
                            defer { connecting = false }
                            do { try await store.refreshRelayWorkspaces() }
                            catch is CancellationError { }
                            catch { failure = error.localizedDescription }
                        }
                    } label: {
                        Label("刷新项目", systemImage: "arrow.clockwise")
                    }.disabled(connecting).accessibilityIdentifier("pairing.refreshWorkspaces")

                }
            }
            Section {
                TextField("电脑名称（可选）", text: $name).textContentType(.name)
                    .accessibilityIdentifier("pairing.name")
                if relayPayload != nil {
                    Label("已识别 ZCode 官方远程连接", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                } else {
                TextField(manualConnection ? "服务地址（https://…）" : "ZCode 连接链接", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pairing.address")
                    .onSubmit { if (try? RelayPairing(scannedURL: address.trimmingCharacters(in: .whitespacesAndNewlines))) != nil { parse(address) } }
                if manualConnection {
                SecureField("连接密钥", text: $token)
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pairing.token")
                }
                }
                if !certificateSHA256.isEmpty {
                    Label("已载入电脑的连接证书", systemImage: "lock.shield")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text(manualConnection ? "自托管连接" : "ZCode 远程控制（推荐）")
            } footer: {
                Text(manualConnection ? "需要已运行的兼容连接服务。SSH 地址本身不是 ZCode 远控链接。密钥保存在钥匙串中。" : "电脑左下角手机图标 → 移动端远程控制 → 复制链接。首次连接后选择项目。")
            }
            if let failure {
                Section { Text(failure).foregroundStyle(.red).font(.subheadline) }
            }
            Section {
                Button {
                    if relayPayload != nil { confirmRelay = true }
                    else if !manualConnection { parse(address); if relayPayload != nil { confirmRelay = true } }
                    else { Task { await connect() } }
                } label: {
                    HStack {
                        Spacer()
                        if connecting { ProgressView().padding(.trailing, 8) }
                        Text(connecting ? "正在连接…" : "连接电脑").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(connecting || choosingWorkspace || (relayPayload == nil && (manualConnection
                    ? (AppStore.validatedURL(address) == nil || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    : (try? RelayPairing(scannedURL: address.trimmingCharacters(in: .whitespacesAndNewlines))) == nil)))
                .accessibilityIdentifier("pairing.connect")
            }
            Section {
                if !choosingWorkspace {
                    Button(manualConnection ? "使用 ZCode 远程链接" : "自托管连接（高级）") {
                        manualConnection.toggle(); address = ""; token = ""; certificateSHA256 = ""; relayPayload = nil; failure = nil
                    }.disabled(connecting).accessibilityIdentifier("pairing.connectionMethod")
                }
                DisclosureGroup("在哪里找到连接信息？") {
                    Text("在电脑 ZCode 左下角点击手机图标，复制远控链接。电脑可以在家里，也可以在外面，但都需要联网且保持 ZCode 运行。\n\n若项目通过 SSH 运行，先在电脑 ZCode 中连接该项目，再从这里接入。手机不会新建 SSH 环境。\n\n自托管方式需要另行部署兼容服务及安全网络，目前不等同于官方桌面远控。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(onboarding ? "连接你的电脑" : "添加连接").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
    private func connectRelay() async {
        guard let raw = relayPayload else { return }
        connecting = true; failure = nil; beganRelay = true
        do {
            try await store.beginRelayPairing(raw, confirmedControllerReplacement: true, attempt: relayAttempt)
            choosingWorkspace = true
        } catch { if !(error is CancellationError) { failure = error.localizedDescription } }
        connecting = false
    }
    private func chooseWorkspace(_ workspace: RelayWorkspace) async {
        connecting = true; failure = nil
        do {
            try await store.completeRelayPairing(workspaceKey: workspace.id, name: name)
            store.sheet = nil; dismiss()
        } catch {
            failure = error.localizedDescription
            store.cancelRelayPairing(attempt: relayAttempt); choosingWorkspace = false
        }
        connecting = false
    }
    private func connect() async {
        connecting = true
        failure = nil
        let profile = ConnectionProfile(id: UUID().uuidString,
            name: name.isEmpty ? URL(string: address)?.host ?? "我的电脑" : name, baseURL: address,
            certificateSHA256: certificateSHA256.isEmpty ? nil : certificateSHA256)
        await store.connect(profile, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        connecting = false
        if store.connection.isOnline { store.sheet = nil; dismiss() }
        else if case .failed(let reason) = store.connection { failure = reason; store.errorMessage = nil }
    }
    private func parse(_ raw: String) {
        guard !connecting, !choosingWorkspace else { return }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pairing = try? RelayPairing(scannedURL: value) {
            manualConnection = false
            relayPayload = value; name = pairing.deviceName
            address = ""; token = ""; certificateSHA256 = ""; failure = nil
            return
        }
        relayPayload = nil
        struct PairingPayload: Decodable {
            var url: String?; var baseURL: String?; var token: String; var name: String?
            var certificateSHA256: String?
        }
        if let data = raw.data(using: .utf8), let payload = try? JSONDecoder().decode(PairingPayload.self, from: data),
           let url = payload.url ?? payload.baseURL, AppStore.validatedURL(url) != nil {
            manualConnection = true
            address = url
            token = payload.token
            name = payload.name ?? ""
            certificateSHA256 = payload.certificateSHA256?.lowercased() ?? ""
            failure = nil
        } else if AppStore.validatedURL(raw) != nil {
            manualConnection = true
            address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            certificateSHA256 = ""
        } else {
            failure = "没有识别到连接信息，请检查后重试。"
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var handled = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    handled = true
                    dataScanner.stopScanning()
                    onCode(value)
                    break
                }
            }
        }
    }
}
