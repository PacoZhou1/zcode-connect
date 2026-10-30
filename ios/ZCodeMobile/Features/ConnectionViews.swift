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
                Section(L10n.tr("我的电脑")) {
                    ForEach(store.profiles.filter { !$0.isAccountRelay || $0.relayAccountScope == store.officialAccount.identity?.scope }) { profile in
                        Button {
                            if profile.isRelay && !(store.activeProfile == profile && store.connection.isOnline && !store.isReferenceMode) { relayReconnect = profile }
                            else { dismiss(); Task { await store.switchComputer(profile) } }
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                VStack(alignment: .leading) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.isRelay ? "\(profile.isCustomRelay ? L10n.tr("自建 Relay · ") + (URL(string: profile.baseURL)?.host ?? L10n.tr("中转服务")) : L10n.tr("ZCode 远程")) · \(profile.relayWorkspaceKey?.split(separator: "/").last.map(String.init) ?? L10n.tr("项目"))" : profile.baseURL).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == store.activeProfileID {
                                    Circle().fill(store.connection.isOnline ? .green : .gray).frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                    NavigationLink { PairingView(embedded: true) } label: {
                        Label(L10n.tr("添加连接"), systemImage: "plus")
                    }
                }

            }
            .navigationTitle(L10n.tr("连接")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("完成")) { dismiss() } } }
        }.presentationDetents([.medium, .large])
        .confirmationDialog(L10n.tr("连接这台电脑？"), isPresented: Binding(get: { relayReconnect != nil }, set: { if !$0 { relayReconnect = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("连接并使用此手机控制")) {
                guard let profile = relayReconnect else { return }
                relayReconnect = nil; dismiss()
                Task { await store.switchComputer(profile, confirmedControllerReplacement: true) }
            }
            Button(L10n.tr("取消"), role: .cancel) { relayReconnect = nil }
        } message: { Text(L10n.tr("如果另一台手机正在控制这台电脑，此次连接可能替换它。电脑上的任务会保留。")) }
    }
}

struct PairingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onboarding = false
    init(embedded: Bool = false, onboarding: Bool = false, advancedHTTP: Bool = false) {
        self.embedded = embedded
        self.onboarding = onboarding
        _manualConnection = State(initialValue: advancedHTTP)
    }
    @State private var manualConnection = false
    @State private var enteringLink = false
    @State private var cameraSettingsNeeded = false
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var certificateSHA256 = ""
    @State private var connecting = false
    @State private var scanner = false
    @State private var failure: String?
    @State private var relayPayload: String?
    @State private var relayServiceHost: String?
    @State private var confirmRelay = false
    @State private var choosingWorkspace = false
    @State private var beganRelay = false
    @State private var relayAttempt = UUID()
    @State private var selectionContext: RelayWorkspaceSelectionContext?
    @State private var isVisible = false
    @State private var httpConnectionTask: Task<Void, Never>?

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .alert(L10n.tr("连接这台电脑？"), isPresented: $confirmRelay) {
            Button(L10n.tr("连接并使用此手机控制")) { Task { await connectRelay() } }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { Text(L10n.tr("将连接“{0}”，通过{1}读取项目。若另一台手机正在控制，可能会替换它的连接。电脑上的任务会保留。", "\(name.isEmpty ? L10n.tr("我的电脑") : name)", "\(relayServiceHost.map { L10n.tr("你的中转服务器 {0}", "\($0)") } ?? L10n.tr("ZCode 官方中转"))")) }
        .onAppear { isVisible = true; restoreWorkspaceSelection() }
        .modifier(OfficialLoginPresentation(enabled: !embedded || store.sheet == nil))
        .onChange(of: store.officialAccount.loginCompletion) { _, _ in
            if isVisible, let identity = store.officialAccount.identity {
                UIAccessibility.post(notification: .announcement, argument: L10n.tr("{0} 登录成功", identity.provider.title) + ". " + L10n.tr("下一步：连接电脑"))
            }
        }
        .onChange(of: store.relayWorkspaceSelection?.id) { _, _ in restoreWorkspaceSelection() }
        .onDisappear {
            isVisible = false
            httpConnectionTask?.cancel(); httpConnectionTask = nil
            if beganRelay && !store.connection.isOnline {
                if let selectionContext { store.cancelRelayPairing(context: selectionContext) }
                else { store.cancelRelayPairing(attempt: relayAttempt) }
            }
        }
        .sheet(isPresented: $scanner) {
            NavigationStack {
                QRScanner(onCode: { payload in
                    scanner = false
                    parse(payload)
                }, onFailure: {
                    scanner = false
                    failure = L10n.tr("相机暂时无法扫描。请重新尝试，或粘贴电脑上的完整连接链接。")
                })
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(L10n.tr("扫描电脑上的二维码"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消")) { scanner = false } } }
            }
        }
    }
    private var content: some View {
        Form {
            if choosingWorkspace {
                Section {
                    Label(L10n.tr("已连接电脑"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(selectionContext?.reason.isEmpty == false ? selectionContext!.reason : L10n.tr("选择要继续的项目。任务和文件仍在电脑上。"))
                        .foregroundStyle(.secondary)
                }
                Section(L10n.tr("选择项目")) {
                    ForEach(store.relayWorkspaces) { workspace in
                        Button { Task { await chooseWorkspace(workspace) } } label: {
                            HStack {
                                Image(systemName: workspace.kind == "remote" ? "network" : "folder")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workspace.workspacePath.split(separator: "/").last.map(String.init) ?? workspace.workspacePath)
                                    Text(workspace.workspacePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if !workspace.canAttach { Text(L10n.tr("请先在电脑上连接此项目")).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }.disabled(connecting || !workspace.canAttach)
                            .accessibilityIdentifier("pairing.workspace.\(workspace.id)")
                    }
                    if store.relayWorkspaces.isEmpty { Text(L10n.tr("还没有项目。请在电脑的 ZCode 打开一个项目，再点刷新。")) }
                    Button {
                        guard isVisible, !connecting, let context = selectionContext else { return }
                        connecting = true; failure = nil
                        Task {
                            defer { if selectionContext == context { connecting = false } }
                            guard isVisible else { return }
                            do { try await store.refreshRelayWorkspaces(context: context) }
                            catch is CancellationError { }
                            catch {
                                if selectionContext == context {
                                    failure = connectionFailureMessage(error)
                                    if !store.isCurrentRelaySelection(context) { choosingWorkspace = false }
                                }
                            }
                        }
                    } label: { Label(L10n.tr("刷新项目"), systemImage: "arrow.clockwise") }
                        .disabled(connecting).accessibilityIdentifier("pairing.refreshWorkspaces")
                }
            } else if manualConnection {
                Section {
                    Text(L10n.tr("仅用于管理员提供的独立 HTTP 任务服务。连接 ZCode 桌面任务，请返回使用扫码连接。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField(L10n.tr("电脑名称（可选）"), text: $name).accessibilityIdentifier("pairing.name")
                    TextField(L10n.tr("服务地址（https://…）"), text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("pairing.address")
                    SecureField(L10n.tr("连接密钥"), text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("pairing.token")
                    if !certificateSHA256.isEmpty { Label(L10n.tr("已载入连接证书"), systemImage: "lock.shield") }
                    clipboardPasteButton
                } header: { Text(L10n.tr("HTTP 桥接")) } footer: { Text(L10n.tr("连接密钥保存在钥匙串中。此方式不会接管原 ZCode 桌面任务。")) }
                connectButton
            } else {
                if store.officialAccount.identities.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "laptopcomputer.and.iphone")
                                .font(.system(size: 40, weight: .light)).foregroundStyle(ZTheme.accent)
                            Text(L10n.tr("在手机上继续电脑任务")).font(.title2.weight(.semibold))
                            Text(relayServiceHost == nil
                                 ? L10n.tr("使用 ZCode 官方中转，无需准备服务器。电脑需保持开机、联网并运行 ZCode。")
                                 : L10n.tr("使用你自己的中转服务器。电脑需保持开机、联网并通过已配置的启动入口运行 ZCode。"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }.listRowBackground(Color.clear)
                }
                if relayPayload == nil {
                    OfficialAccountSection(showDevices: false)
                    Section {
                        if let identity = store.officialAccount.identity {
                            Label(L10n.tr("{0} 登录成功", identity.provider.title), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).accessibilityIdentifier("pairing.loginSuccess")
                            Text(L10n.tr("在电脑上登录同一账号，开启远程控制，然后扫描二维码。"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }

                        Button { Task { await startScanning() } } label: {
                            Label(L10n.tr("扫描电脑二维码"), systemImage: "qrcode.viewfinder").fontWeight(.semibold)
                        }.accessibilityIdentifier("pairing.scan").disabled(connecting || store.officialAccount.signingIn)
                        Button { enteringLink.toggle() } label: {
                            Label(L10n.tr("粘贴连接链接"), systemImage: "link")
                        }.accessibilityIdentifier("pairing.showPaste").disabled(connecting)
                        if enteringLink {
                            TextField(L10n.tr("电脑上的完整连接链接"), text: $address, axis: .vertical)
                                .lineLimit(2...4).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .privacySensitive().accessibilityIdentifier("pairing.address")
                            HStack {
                                clipboardPasteButton
                                Spacer()
                                Button(L10n.tr("识别链接")) { parse(address) }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .accessibilityIdentifier("pairing.recognize")
                            }.buttonStyle(.borderless)
                        }
                    } header: {
                        Text(store.officialAccount.identity == nil ? L10n.tr("扫码或粘贴链接") : L10n.tr("下一步：连接电脑"))
                    }
                    OfficialComputerSection(onSelect: { device in
                        parse(device.pairingURL()); confirmRelay = relayPayload != nil
                    })
                    Section(L10n.tr("连接帮助")) {
                        NavigationLink { ConnectionGuideView() } label: {
                            Text(L10n.tr("还没安装，或找不到二维码？"))
                        }.accessibilityIdentifier("pairing.guide")
                    }
                } else {
                    if (try? RelayPairing(payload: relayPayload ?? ""))?.usesAccount == true {
                        OfficialAccountSection(showDevices: false)
                    }
                    Section(L10n.tr("确认要连接的电脑")) {
                        Label(name.isEmpty ? L10n.tr("我的电脑") : name, systemImage: "laptopcomputer")
                            .accessibilityIdentifier("pairing.recognizedComputer")
                        Label(relayServiceHost.map { L10n.tr("你的中转 · {0}", "\($0)") } ?? L10n.tr("ZCode 官方中转"), systemImage: "network")
                            .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("pairing.recognizedService")
                        Text(L10n.tr("连接后选择项目，即可查看和继续任务。"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(L10n.tr("换一个二维码或链接")) {
                            relayPayload = nil; relayServiceHost = nil; address = ""; name = ""; failure = nil
                        }.disabled(connecting).accessibilityIdentifier("pairing.replace")
                    }
                    connectButton
                }
            }
            if connecting {
                Section { ProgressView(choosingWorkspace ? L10n.tr("正在读取项目任务…") : L10n.tr("正在连接电脑并读取项目…")) }
            }
            if let failure {
                Section(L10n.tr("需要处理")) {
                    Text(failure).font(.subheadline).accessibilityIdentifier("pairing.failure")
                    if cameraSettingsNeeded {
                        Button(L10n.tr("打开系统设置")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    NavigationLink(L10n.tr("查看连接排障")) { ConnectionGuideView() }
                }
            }
            if !choosingWorkspace && !manualConnection {
                Section {
                    NavigationLink { SelfHostedConnectionGuideView() } label: {
                        Label(L10n.tr("使用自己的中转服务器"), systemImage: "server.rack")
                    }.accessibilityIdentifier("pairing.selfHostedGuide")
                    if onboarding, !store.profiles.isEmpty {
                        Button(L10n.tr("选择已添加的电脑"), systemImage: "laptopcomputer") { store.sheet = .connections }
                    }
                    if onboarding {
                        Button(L10n.tr("先体验一下"), systemImage: "play.rectangle") { store.enterReferenceMode() }
                        Text(L10n.tr("体验使用示例任务，不连接电脑。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Link(L10n.tr("隐私政策"), destination: URL(string: "https://zcode-remote-support.zch1234512345.chatgpt.site/privacy.html")!)
                            .accessibilityIdentifier("pairing.privacyPolicy")
                    }
                }.disabled(connecting)
            }
        }
        .navigationTitle(manualConnection ? L10n.tr("HTTP 桥接") : choosingWorkspace ? L10n.tr("选择项目") : L10n.tr("连接你的电脑"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onboarding {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.sheet = .settings } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L10n.tr("设置")).accessibilityIdentifier("pairing.settings")
                }
            }
            if !embedded && !onboarding {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消")) { dismiss() } }
            }
        }
    }

    private var connectButton: some View {
        Button {
            if relayPayload != nil { confirmRelay = true }
            else if manualConnection { httpConnectionTask = Task { await connect() } }
        } label: {
            Text(L10n.tr("连接这台电脑")).fontWeight(.semibold).frame(maxWidth: .infinity)
        }
        .disabled(connecting || ((try? RelayPairing(payload: relayPayload ?? ""))?.usesAccount == true && store.officialAccount.identity == nil) || (relayPayload == nil && (!manualConnection || AppStore.validatedURL(address) == nil || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
        .accessibilityIdentifier("pairing.connect")
    }

    private var clipboardPasteButton: some View {
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            parse(value)
        }
        .accessibilityLabel(L10n.tr("从剪贴板粘贴连接信息"))
        .accessibilityIdentifier("pairing.paste")
    }

    private func connectionFailureMessage(_ error: Error) -> String {
        if case .failed(let message) = store.connection { return message }
        return error.localizedDescription
    }

    private func startScanning() async {
        cameraSettingsNeeded = false; failure = nil
        guard DataScannerViewController.isSupported else {
            enteringLink = true
            failure = L10n.tr("这台设备不支持扫码。请使用下方的粘贴连接链接。")
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = status == .authorized
        if status == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .video) }
        guard isVisible else { return }
        guard granted else {
            cameraSettingsNeeded = status != .restricted
            enteringLink = true
            failure = L10n.tr("无法使用相机。你可以在系统设置中允许相机访问，或粘贴电脑上的连接链接。")
            return
        }
        guard DataScannerViewController.isAvailable else {
            enteringLink = true; failure = L10n.tr("相机暂时不可用，请稍后重试或粘贴连接链接。"); return
        }
        scanner = true
    }
    private func restoreWorkspaceSelection() {
        if let selectionContext, !store.isCurrentRelaySelection(selectionContext) {
            choosingWorkspace = false
        }
        guard let context = store.relayWorkspaceSelection,
              store.isCurrentRelaySelection(context),
              !onboarding || store.sheet == nil else { return }
        selectionContext = context
        relayAttempt = context.attempt
        name = context.name
        beganRelay = true; choosingWorkspace = true; connecting = false; failure = nil
        relayPayload = nil; relayServiceHost = nil; address = ""; token = ""; certificateSHA256 = ""
    }
    private func connectRelay() async {
        guard isVisible, !connecting, let raw = relayPayload else { return }
        let attempt = UUID(); relayAttempt = attempt
        selectionContext = nil
        connecting = true; failure = nil; beganRelay = true
        do {
            let context = try await store.beginRelayPairing(raw, confirmedControllerReplacement: true, attempt: attempt)
            guard isVisible, relayAttempt == attempt, store.isCurrentRelaySelection(context) else { return }
            selectionContext = context
            choosingWorkspace = true
        } catch { if relayAttempt == attempt, !(error is CancellationError) { failure = connectionFailureMessage(error) } }
        if relayAttempt == attempt { connecting = false }
    }
    private func chooseWorkspace(_ workspace: RelayWorkspace) async {
        guard isVisible, !connecting, let context = selectionContext, store.isCurrentRelaySelection(context) else { return }
        connecting = true; failure = nil
        do {
            try await store.completeRelayPairing(workspaceKey: workspace.id, name: name, context: context)
            guard isVisible, selectionContext == context, store.isCurrentRelaySelection(context) else { return }
            store.sheet = nil; dismiss()
        } catch is CancellationError {
        } catch {
            if selectionContext == context {
                failure = connectionFailureMessage(error)
                if !["relay_workspace_unavailable", "relay_busy"].contains((error as? BridgeFailure)?.code ?? "") {
                    store.cancelRelayPairing(context: context); choosingWorkspace = false
                }
            }
        }
        if selectionContext == context { connecting = false }
    }
    private func connect() async {
        guard isVisible, !connecting else { return }
        connecting = true
        defer { connecting = false }
        failure = nil
        let profile = ConnectionProfile(id: UUID().uuidString,
            name: name.isEmpty ? URL(string: address)?.host ?? L10n.tr("我的电脑") : name, baseURL: address,
            certificateSHA256: certificateSHA256.isEmpty ? nil : certificateSHA256)
        await store.connect(profile, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard isVisible else { return }
        connecting = false
        if store.connection.isOnline { store.sheet = nil; dismiss() }
        else if case .failed(let reason) = store.connection { failure = reason; store.errorMessage = nil }
    }
    private func parse(_ raw: String) {
        guard !connecting, !choosingWorkspace else { return }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A replacement payload must never reuse another host's address or credential.
        address = ""; token = ""; name = ""; certificateSHA256 = ""; relayPayload = nil; relayServiceHost = nil; failure = nil; cameraSettingsNeeded = false
        if RelayPairing.isAccountDeviceList(value) {
            manualConnection = false
            store.officialAccount.restore()
            if store.officialAccount.identity != nil { Task { await store.officialAccount.refreshDevices() } }
            return
        }
        if let pairing = try? RelayPairing(payload: value) {
            manualConnection = false
            relayPayload = value; relayServiceHost = pairing.isSelfHosted ? pairing.profileURL.host : nil; name = pairing.deviceName
            address = ""; token = ""; certificateSHA256 = ""; failure = nil
            return
        }
        relayPayload = nil; relayServiceHost = nil
        if let data = value.data(using: .utf8), let envelope = try? RelayJSON(data: data), envelope.object?["transport"] != nil {
            failure = L10n.tr("自建 Relay 连接信息无效，请核对同一服务的加密配对地址和中转地址。")
            return
        }
        guard manualConnection else {
            failure = L10n.tr("没有识别到连接二维码。请从电脑 ZCode 的远程控制窗口重新扫码或复制完整链接；不要填写网站首页、服务器 IP 或模型 API Key。")
            return
        }
        struct PairingPayload: Decodable {
            var url: String?; var baseURL: String?; var token: String; var name: String?
            var certificateSHA256: String?
        }
        if let data = value.data(using: .utf8), let payload = try? JSONDecoder().decode(PairingPayload.self, from: data),
           let url = payload.url ?? payload.baseURL, AppStore.validatedURL(url) != nil {
            address = url; token = payload.token; name = payload.name ?? ""
            certificateSHA256 = payload.certificateSHA256?.lowercased() ?? ""
        } else if AppStore.validatedURL(value) != nil,
                  URLComponents(string: value)?.query == nil {
            address = value
        } else {
            failure = L10n.tr("没有识别到 HTTP 桥接配置。请使用管理员提供的服务地址与连接密钥。")
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { DispatchQueue.main.async { onFailure() } }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var handled = false
        var onFailure: () -> Void
        init(onCode: @escaping (String) -> Void, onFailure: @escaping () -> Void) { self.onCode = onCode; self.onFailure = onFailure }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !handled else { return }; handled = true; onFailure()
        }
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


struct ConnectionGuideView: View {
    var body: some View {
        List {
            Section(L10n.tr("使用 ZCode 官方中转")) {
                Text(L10n.tr("无需购买服务器、配置域名或填写密钥。手机和电脑都能联网即可，任务仍由电脑执行。"))
            }
            Section(L10n.tr("1 · 在电脑准备 ZCode")) {
                Text(L10n.tr("在电脑访问 zcode.z.ai，按官方说明安装并完成模型配置。打开一个项目，先确认电脑上能正常使用任务。"))
                Link(L10n.tr("打开 ZCode 官方网站"), destination: URL(string: "https://zcode.z.ai")!)
                Text(L10n.tr("请选择与电脑相同的平台和账号。"))
            }
            Section(L10n.tr("2 · 显示连接二维码")) {
                Label(L10n.tr("点击电脑 ZCode 左下角的手机图标"), systemImage: "iphone")
                Text(L10n.tr("打开“移动端远程控制”，等待二维码出现。如果提供开启开关，先开启。无需改成自建服务器。"))
                Link(L10n.tr("查看官方图文说明"), destination: URL(string: "https://zcode.z.ai/cn/docs/remote-control")!)
            }
            Section(L10n.tr("在 App 中选择电脑")) {
                Text(L10n.tr("登录后选择在线电脑，再选择项目。也可以扫描二维码或粘贴完整链接。"))
                Text(L10n.tr("用系统相机扫描官方二维码会打开官方网页。要在这个 App 中使用，请从 App 内扫码。"))
                Text(L10n.tr("首次验证：打开一条已有任务，核对正文；发送一条测试消息并等到回复。再切换蜂窝网络确认能继续访问。"))
            }
            Section(L10n.tr("之后怎么用")) {
                Text(L10n.tr("连接会保存，下次打开 App 会尝试重连。电脑需要保持运行和联网；中转服务器不能替休眠或关机的电脑执行任务。"))
                Text(L10n.tr("同一桌面窗口同时只支持一个手机控制连接。另一台手机或网页接管后，可在“我的电脑”中手动连接。"))
            }
            Section(L10n.tr("遇到问题")) {
                DisclosureGroup(L10n.tr("二维码不出现或电脑连不上")) {
                    Text(L10n.tr("确认电脑能联网、ZCode 已打开项目且远控已开启。更新桌面版本后出现问题时，先核对版本兼容性。曾配置自建中转的电脑，应先按部署文档恢复官方启动配置，不能只换手机链接。"))
                }
                DisclosureGroup(L10n.tr("二维码失效或身份验证失败")) {
                    Text(L10n.tr("确认链接属于当前电脑和中转服务。官方连接可在电脑重新生成二维码，再用 App 扫描；自建连接先让管理员核对登记与轮换许可，不要反复刷新二维码。"))
                }
                DisclosureGroup(L10n.tr("连接成功但没有项目")) {
                    Text(L10n.tr("在电脑的同一个 ZCode 窗口打开项目。SSH 等远程项目先在电脑端连接成功，再回手机点“刷新项目”。"))
                }
                DisclosureGroup(L10n.tr("离开 Wi-Fi 后无法连接")) {
                    Text(L10n.tr("确认 App 可使用蜂窝数据、电脑仍在线。自建用户还需检查外网域名、TLS 和 WebSocket 代理。不要填写家中内网 IP 来替代配对链接。"))
                }
            }
        }.navigationTitle(L10n.tr("电脑端准备")).navigationBarTitleDisplayMode(.inline)
    }
}

struct SelfHostedConnectionGuideView: View {
    var body: some View {
        List {
            Section {
                Label(L10n.tr("使用自己的中转服务器"), systemImage: "server.rack").font(.headline)
                Text(L10n.tr("适合已有常驻服务器、希望自行维护中转的用户。把下面的工具包交给你电脑上的 AI agent，由它按你的环境部署和适配。"))
                Text(L10n.tr("服务器负责转发；工作电脑仍需开机并运行 ZCode。只开放 SSH 或填写服务器 IP 不能完成配对。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section(L10n.tr("1 · 导出部署工具包")) {
                Text(L10n.tr("此工具包用于旧协议。新版桌面还需适配账号与令牌服务，请勿向自建中转提供官方登录凭据。"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let kit = Bundle.main.url(forResource: "ZCode-Self-Hosted-Kit", withExtension: "zip") {
                    ShareLink(item: kit) { Label(L10n.tr("导出文档与部署工具"), systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("pairing.exportKit")
                } else {
                    Text(L10n.tr("此构建缺少部署工具包，请向 App 提供者获取 ZCode-Self-Hosted-Kit.zip。"))
                }
                Text(L10n.tr("包含完整部署文档、Relay 源码、macOS 启动工具、Linux 服务示例、协议约束、测试与回滚步骤。解压后让 AI agent 从 START_HERE.md 开始。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section(L10n.tr("2 · 在电脑完成部署")) {
                Text(L10n.tr("准备可访问的 HTTPS 域名，让 agent 配置中转、登记工作电脑，并生成你自己的桌面启动入口。当前启动工具面向已核验的 macOS 官方安装包；其他平台与版本需要适配。"))
                Text(L10n.tr("以后使用保存的启动入口打开 ZCode。电脑更新后先检查兼容性；不要绕过启动工具的版本检查。"))
            }
            Section(L10n.tr("3 · 回 App 直接扫码")) {
                Text(L10n.tr("电脑通过自己的中转成功登记后，在远控窗口显示新的二维码。返回 App 连接页直接扫描，核对中转域名与电脑名称，再选择项目。也可粘贴完整配对链接或旧版 JSON 连接信息。"))
                Text(L10n.tr("无需再用系统相机打开网页、复制 JSON。连接成功后，按文档验证任务收发、外网访问和重启恢复。"))
            }
            Section(L10n.tr("其他兼容服务")) {
                NavigationLink { PairingView(embedded: true, advancedHTTP: true) } label: {
                    Text(L10n.tr("HTTP 桥接（高级）"))
                }.accessibilityIdentifier("pairing.advancedHTTP")
                Text(L10n.tr("仅在管理员明确提供 HTTP 桥接服务时使用；自建中转不使用这个入口。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(L10n.tr("自己的中转服务器")).navigationBarTitleDisplayMode(.inline)
    }
}
