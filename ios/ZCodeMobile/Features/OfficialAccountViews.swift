import SwiftUI
import SafariServices

/// Safari owns the official sign-in page. The app only polls its own authorization flow;
/// it cannot inspect passwords, cookies, page contents, or another browser's credentials.
private struct OfficialLoginBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Present once from the screen, never from a Form's conditional Section rows.
struct OfficialLoginPresentation: ViewModifier {
    @Environment(AppStore.self) private var store
    func body(content: Content) -> some View {
        let account = store.officialAccount
        content.sheet(isPresented: Binding(get: { account.authorizationURL != nil }, set: { value in
            if !value && account.signingIn { account.cancelLogin() }
        }), onDismiss: {
            if account.signingIn { account.cancelLogin() }
        }) {
            if let url = account.authorizationURL { OfficialLoginBrowser(url: url).ignoresSafeArea() }
        }
    }
}

struct OfficialAccountSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    var showDevices = true
    var onSelect: ((RelayAccountDevice) -> Void)?

    var body: some View {
        let account = store.officialAccount
        Group {
            Section(L10n.tr("ZCode 账号")) {
                if let identity = account.identity {
                    HStack {
                        Label(identity.name, systemImage: "person.crop.circle")
                        Spacer()
                        Menu {
                            Button(L10n.tr("退出登录"), role: .destructive) {
                                do { try account.signOut() } catch { account.failure = error.localizedDescription }
                            }
                        } label: { Text(identity.provider.title).foregroundStyle(.secondary) }
                        .accessibilityLabel(L10n.tr("账号选项"))
                    }
                    .accessibilityIdentifier("account.identity")
                } else if account.signingIn {
                    ProgressView(L10n.tr("正在等待登录…"))
                    Button(L10n.tr("取消")) { account.cancelLogin() }
                } else {
                    ForEach(RelayAccountProvider.allCases) { provider in
                        Button { account.signIn(provider) } label: {
                            HStack { Text(L10n.tr("登录 {0}", provider.title)); Spacer(); Image(systemName: "arrow.up.forward") }
                        }
                        .accessibilityIdentifier("account.signIn.\(provider.rawValue)")
                    }
                    Text(L10n.tr("请选择与电脑相同的平台和账号。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure = account.failure {
                    Text(failure).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("account.failure")
                }
            }
            if showDevices, account.identity != nil {
                Section(L10n.tr("电脑")) {
                    if account.loadingDevices && account.devices.isEmpty {
                        ProgressView(L10n.tr("正在读取电脑…"))
                    } else if account.devices.isEmpty && account.failure == nil {
                        ContentUnavailableView(L10n.tr("暂无电脑"), systemImage: "laptopcomputer",
                            description: Text(L10n.tr("在电脑上登录同一账号，并开启远程控制。")))
                    }
                    ForEach(RelayAccountComputer.group(account.devices)) { computer in
                        if computer.onlineConnections.count > 1 {
                            Menu {
                                ForEach(computer.onlineConnections) { device in
                                    Button { onSelect?(device) } label: {
                                        Label { Text(device.createdAt, style: .time) } icon: { Image(systemName: "macwindow") }
                                    }
                                }
                            } label: { computerLabel(computer) }
                            .disabled(account.loadingDevices || account.failure != nil || onSelect == nil)
                            .accessibilityIdentifier("account.computer.\(computer.id)")
                        } else {
                            Button {
                                if let device = computer.onlineConnections.first { onSelect?(device) }
                            } label: { computerLabel(computer) }
                            .disabled(computer.onlineConnections.isEmpty || account.loadingDevices || account.failure != nil || onSelect == nil)
                            .accessibilityIdentifier("account.computer.\(computer.id)")
                        }
                    }
                    Button {
                        Task { await account.refreshDevices() }
                    } label: {
                        Label(L10n.tr("刷新"), systemImage: "arrow.clockwise")
                    }
                    .disabled(account.loadingDevices)
                    .accessibilityIdentifier("account.refreshDevices")
                }
            }
        }
        .task(id: account.identity?.scope) {
            account.restore()
            if showDevices, account.identity != nil { await account.refreshDevices() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, showDevices, account.identity != nil {
                Task { await account.refreshDevices() }
            }
        }
    }

    private func computerLabel(_ computer: RelayAccountComputer) -> some View {
        HStack {
            Image(systemName: "laptopcomputer").foregroundStyle(.primary)
            Text(computer.name).foregroundStyle(.primary)
            Spacer()
            if computer.onlineConnections.isEmpty {
                Text(L10n.tr("离线")).foregroundStyle(.secondary).font(.caption)
            } else {
                if computer.onlineConnections.count > 1 { Text(computer.onlineConnections.count, format: .number).foregroundStyle(.secondary) }
                Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel(L10n.tr("在线"))
            }
        }
    }
}
