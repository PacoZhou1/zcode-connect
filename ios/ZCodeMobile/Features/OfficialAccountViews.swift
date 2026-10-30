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
    var enabled = true
    func body(content: Content) -> some View {
        let account = store.officialAccount
        content.sheet(isPresented: Binding(get: { enabled && account.authorizationURL != nil }, set: { value in
            if enabled && !value { account.browserDidDismiss() }
        }), onDismiss: {
            if enabled { account.browserDidDismiss() }
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
                ForEach(RelayAccountProvider.allCases) { provider in
                    if let identity = account.identities[provider] {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.title).foregroundStyle(.primary)
                                Text(identity.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                            }
                            Spacer()
                            Menu {
                                if account.identity?.provider != provider {
                                    Button(L10n.tr("使用此账号")) { account.useAccount(provider) }
                                }
                                Button(L10n.tr("退出登录"), role: .destructive) {
                                    do { try account.signOut(provider) } catch { account.failure = error.localizedDescription }
                                }
                            } label: {
                                Text(account.identity?.provider == provider ? L10n.tr("已登录 · 当前使用") : L10n.tr("已登录"))
                                    .font(.subheadline)
                            }
                            .accessibilityIdentifier("account.options.\(provider.rawValue)")
                        }
                        .accessibilityElement(children: .contain)
                    } else if account.loginProvider == provider {
                        HStack {
                            Text(provider.title)
                            Spacer()
                            ProgressView().controlSize(.small)
                            Text(account.confirmingLogin ? L10n.tr("正在确认登录…") : L10n.tr("正在等待登录…"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button(L10n.tr("取消")) { account.cancelLogin() }
                    } else {
                        Button { account.signIn(provider) } label: {
                            HStack {
                                Text(provider.title)
                                Spacer()
                                Text(L10n.tr("未登录")).font(.subheadline).foregroundStyle(.secondary)
                                Image(systemName: "arrow.up.forward").font(.caption)
                            }
                        }
                        .disabled(account.signingIn)
                        .accessibilityLabel(L10n.tr("登录 {0}", provider.title))
                        .accessibilityIdentifier("account.signIn.\(provider.rawValue)")
                    }
                }
                if account.identity == nil {
                    Text(L10n.tr("请选择与电脑相同的平台和账号。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure = account.failure {
                    Text(failure).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("account.failure")
                }
            }
            if showDevices { OfficialComputerSection(onSelect: onSelect) }
        }
        .task(id: account.identity?.scope) {
            account.restore()
        }
    }

}

struct OfficialComputerSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    var onSelect: ((RelayAccountDevice) -> Void)?
    var body: some View {
        let account = store.officialAccount
        Group {
            if account.identity != nil {
                Section(L10n.tr("电脑")) {
                    if account.loadingDevices && account.devices.isEmpty {
                        ProgressView(L10n.tr("正在读取电脑…"))
                    } else if account.devices.isEmpty && account.failure == nil {
                        Text(L10n.tr("电脑暂未出现在列表中，可扫描电脑上的二维码连接。"))
                            .font(.subheadline).foregroundStyle(.secondary)
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
                    Button { Task { await account.refreshDevices() } } label: {
                        Label(L10n.tr("刷新"), systemImage: "arrow.clockwise")
                    }
                    .disabled(account.loadingDevices).accessibilityIdentifier("account.refreshDevices")
                }
            }
        }
        .task(id: account.identity?.scope) {
            if account.identity != nil { await account.refreshDevices() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, account.identity != nil { Task { await account.refreshDevices() } }
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
