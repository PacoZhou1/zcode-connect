import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var renameSession: RemoteSession?
    @State private var renameText = ""
    @State private var renameScope: String?
    @State private var confirmRelayReconnect = false
    @State private var computerToConfirm: ConnectionProfile?

    private struct SessionGroup: Identifiable {
        var id: String
        var sessions: [RemoteSession]
    }

    private var connectionScope: String {
        "\(store.isReferenceMode)|\(store.activeProfileID ?? "")|\(store.activeProfile?.baseURL ?? "")"
    }

    private func beginRename(_ session: RemoteSession) {
        renameScope = connectionScope
        renameText = session.title
        renameSession = session
    }

    private var groups: [SessionGroup] {
        let filtered = store.sessions.filter {
            $0.isArchived == store.showArchived &&
            (search.isEmpty || $0.title.localizedStandardContains(search) || $0.projectName.localizedStandardContains(search))
        }
        if store.sortOrder == .project {
            let names = Array(Set(filtered.map(\.projectName))).sorted()
            return names.map { name in SessionGroup(id: name, sessions: filtered.filter { $0.projectName == name }) }
        }
        var ordered = filtered
        if !store.isReferenceMode || store.sortOrder == .recent {
            ordered.sort { a, b in
                if store.sortOrder == .priority {
                    if a.status == .waiting && b.status != .waiting { return true }
                    if b.status == .waiting && a.status != .waiting { return false }
                    if a.isPinned != b.isPinned { return a.isPinned }
                }
                return a.updatedAt > b.updatedAt
            }
        }
        var result: [SessionGroup] = []
        for session in ordered {
            let label = groupTitle(session.updatedAt)
            if let index = result.firstIndex(where: { $0.id == label }) { result[index].sessions.append(session) }
            else { result.append(SessionGroup(id: label, sessions: [session])) }
        }
        return result
    }

    var body: some View {
        Group {
            if !store.connection.isOnline && store.sessions.isEmpty {
                connectionEmptyState
            } else {
                sessionList
            }
        }
        .background(ZTheme.background)
        .confirmationDialog("切换到这台电脑？", isPresented: Binding(get: { computerToConfirm != nil }, set: { if !$0 { computerToConfirm = nil } }), titleVisibility: .visible) {
            Button("连接并切换") {
                guard let profile = computerToConfirm else { return }
                computerToConfirm = nil
                search = ""; collapsed = []
                Task { await store.switchComputer(profile, confirmedControllerReplacement: true) }
            }
            Button("取消", role: .cancel) { computerToConfirm = nil }
        } message: {
            Text("连接 \(computerToConfirm?.name ?? "所选电脑") 并加载其任务。如果另一台手机正在控制该电脑，此次连接可能替换它；电脑上的任务会继续运行。")
        }
        .confirmationDialog("重新连接 ZCode 远程控制？", isPresented: $confirmRelayReconnect, titleVisibility: .visible) {
            Button("连接这台电脑") {
                if let profile = store.activeProfile { Task { await store.connect(profile, confirmedControllerReplacement: true) } }
            }
        } message: { Text("同一电脑工作区只允许一个移动端控制器。连接后可能替换当前已连接的手机。") }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { store.sheet = .connections } label: {
                    MenuLinesGlyph().stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .frame(width: 22, height: 24)
                }.tint(.primary).accessibilityLabel("打开连接与导航")
                    .accessibilityIdentifier("home.sidebar")
            }
            ToolbarItem(placement: .principal) {
                Button { store.sheet = .connections } label: {
                    VStack(spacing: 2) {
                        Text(store.showArchived ? "已归档任务" : "远程")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Circle().fill(store.connection.isOnline ?
                                          (store.isReferenceMode || store.streamConnected ? Color.green : Color.orange) : Color.gray)
                                .frame(width: 6, height: 6)
                            Image(systemName: "laptopcomputer").font(.system(size: 11))
                            Text(store.connection.isOnline && !store.isReferenceMode && !store.streamConnected
                                 ? "\(store.hostName) · 正在重连" : store.hostName).font(.system(size: 13))
                        }.foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).accessibilityLabel("当前电脑，\(store.hostName)，\(store.connection.label)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                homeMenu
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                GlassSearchField(text: $search, placeholder: "搜索聊天")
                if store.connection.isOnline {
                    Button { store.sheet = .voice } label: {
                        VoiceBarsGlyph().stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).frame(width: 20, height: 22)
                            .frame(width: 36, height: 36)
                    }.buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("语音创建任务").accessibilityIdentifier("home.voice")
                        .measureLayout("home.voice")
                }
                Button {
                    if store.connection.isOnline { store.path.append(.newSession) }
                    else { store.sheet = .pairing }
                } label: {
                    HStack(spacing: 10) {
                        ComposeGlyph().stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)).frame(width: 25, height: 25)
                        if !store.connection.isOnline { Text("聊天").font(.system(size: 18, weight: .semibold)) }
                    }.frame(width: store.connection.isOnline ? 36 : 106, height: store.connection.isOnline ? 36 : 34)
                }.buttonStyle(.glassProminent).buttonBorderShape(store.connection.isOnline ? .circle : .capsule)
                    .frame(width: store.connection.isOnline ? 48 : 120, height: 48)
                    .accessibilityLabel("新建聊天").accessibilityIdentifier("home.new")
                    .measureLayout("home.new")
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, -5.333333)
        }
        .alert("重命名任务", isPresented: Binding(get: { renameSession != nil }, set: { if !$0 { renameSession = nil } })) {
            TextField("任务名称", text: $renameText)
            Button("取消", role: .cancel) { renameSession = nil }
            Button("保存") {
                if renameScope == connectionScope, let id = renameSession?.id {
                    store.rename(id, title: renameText)
                }
                renameSession = nil
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: connectionScope) { _, _ in
            renameSession = nil; renameScope = nil
            search = ""; collapsed = []
        }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            if let id = renameSession?.id, !ids.contains(id) { renameSession = nil; renameScope = nil }
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.sessionListTruncated {
                    InlineNotice(symbol: "list.bullet", text: "已加载 \(store.sessions.count) 个任务，电脑还有未返回的记录。当前搜索只覆盖已加载任务。")
                        .padding(.bottom, 16)
                }
                if store.isReferenceMode && !store.referenceReview {
                    HStack {
                        Text("界面体验").font(.caption.weight(.medium))
                        Spacer()
                        Button("连接我的电脑") { store.leaveReferenceMode(); store.sheet = .pairing }
                            .font(.caption)
                    }.foregroundStyle(.secondary).padding(.bottom, 20)
                }
                if store.showArchived {
                    Button { store.showArchived = false } label: {
                        Label("返回全部任务", systemImage: "arrow.left").font(.subheadline)
                    }.padding(.bottom, 20)
                }
                if groups.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "还没有任务" : "没有找到聊天",
                        systemImage: search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                        description: Text(search.isEmpty ? "创建一个任务，从手机继续你的工作。" : "试试其他任务名称或项目名称。"))
                        .padding(.top, 100)
                }
                ForEach(groups) { group in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if collapsed.contains(group.id) { collapsed.remove(group.id) }
                            else { collapsed.insert(group.id) }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Text(group.id).font(.system(size: 17, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(collapsed.contains(group.id) ? -90 : 0))
                        }.foregroundStyle(.primary).frame(minHeight: 30, alignment: .leading)
                    }.buttonStyle(.plain).padding(.bottom, 21)
                        .padding(.top, group.id == groups.first?.id ? 0 : -3)
                    if !collapsed.contains(group.id) {
                        ForEach(group.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 31).padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("home.sessions")
    }

    private func sessionRow(_ session: RemoteSession) -> some View {
        Button { store.setUnread(false, sessionID: session.id); store.path.append(.session(session.id)) } label: {
            VStack(alignment: .leading, spacing: 6.666667) {
                HStack(spacing: 8) {
                    if session.status == .running || session.status == .waiting { StatusDot(status: session.status) }
                    if store.isUnread(session.id) { Circle().fill(ZTheme.accent).frame(width: 7, height: 7).accessibilityLabel("未读") }
                    Text(session.title).font(.system(size: 17))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(.primary)
                HStack(spacing: 4.666667) {
                    Group {
                        if session.projectName == "聊天" {
                            ChatGlyph().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        } else {
                            FolderGlyph().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        }
                    }.frame(width: 14, height: 14).frame(width: 16).offset(y: -0.666667)
                    Text(session.projectName).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    if session.additions > 0 || session.deletions > 0 {
                        ChangeCount(additions: session.additions, deletions: session.deletions)
                    }
                }.foregroundStyle(ZTheme.listSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 23.333333).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("session.\(session.id)")
        .measureLayout("row.\(session.id)")
        .overlay {
            SessionContextInteraction(title: session.title,
                identity: "\(store.isReferenceMode)|\(store.activeProfileID ?? "")|\(store.activeProfile?.baseURL ?? "")|\(session.id)",
                preview: AnyView(ConversationPreview(sessionID: session.id).environment(store)),
                actions: [
                    SessionContextAction(title: session.isPinned ? "取消置顶" : "置顶", symbol: session.isPinned ? "pin.slash" : "pin", perform: { [pinned = !session.isPinned] in store.setPinned(pinned, sessionID: session.id) }),
                    SessionContextAction(title: "重命名", symbol: "pencil", perform: { beginRename(session) }),
                    SessionContextAction(title: store.isUnread(session.id) ? "标记为已读" : "标记为未读", symbol: "circle.fill", perform: { [unread = !store.isUnread(session.id)] in store.setUnread(unread, sessionID: session.id) }),
                    SessionContextAction(title: "复制对话串 ID", symbol: "square.on.square", perform: { store.copy(session.id) }),
                    SessionContextAction(title: session.isArchived ? "取消归档" : "归档", symbol: "archivebox", destructive: !session.isArchived, perform: { store.archive(session.id, archived: !session.isArchived) })
                ], open: { store.setUnread(false, sessionID: session.id); store.path.append(.session(session.id)) })
                .accessibilityHidden(true)
        }
        .accessibilityAction(named: Text(session.isPinned ? "取消置顶" : "置顶")) { store.togglePin(session.id) }
        .accessibilityAction(named: Text("重命名")) { beginRename(session) }
        .accessibilityAction(named: Text(store.isUnread(session.id) ? "标记为已读" : "标记为未读")) { store.setUnread(!store.isUnread(session.id), sessionID: session.id) }
        .accessibilityAction(named: Text("复制对话串 ID")) { store.copy(session.id) }
        .accessibilityAction(named: Text(session.isArchived ? "取消归档" : "归档")) { store.archive(session.id, archived: !session.isArchived) }
    }

    private var homeMenu: some View {
        @Bindable var store = store
        return Menu {
            Section {
                Menu {
                    ForEach(store.profiles) { profile in
                        Button {
                            if profile.isRelay && !(store.activeProfile == profile && store.connection.isOnline && !store.isReferenceMode) {
                                computerToConfirm = profile
                            } else {
                                search = ""; collapsed = []
                                Task { await store.switchComputer(profile) }
                            }
                        } label: {
                            Label(computerLabel(profile) + (store.activeProfileID == profile.id && !store.isReferenceMode ? " · \(store.connection.label)" : ""),
                                  systemImage: store.activeProfileID == profile.id && !store.isReferenceMode ? "checkmark" : "laptopcomputer")
                        }
                        .accessibilityIdentifier("home.computer.\(profile.id)")
                    }
                    if store.profiles.isEmpty { Text("还没有添加电脑") }
                    Divider()
                    Button("添加电脑", systemImage: "plus") { store.sheet = .pairing }
                    Button("管理电脑", systemImage: "laptopcomputer") { store.sheet = .connections }
                } label: { Label("切换电脑", systemImage: "laptopcomputer") }
            }
            Picker("排序方式", selection: $store.sortOrder) {
                ForEach(SortOrder.allCases) { sort in Label(sort.rawValue, systemImage: sort.symbol).tag(sort) }
            }.pickerStyle(.inline)
            Section("管理") {
                Button("云端任务", systemImage: "cloud") {
                    store.errorMessage = "当前连接使用电脑上的 ZCode。云端任务需要对应的服务支持。"
                }
                Button(store.showArchived ? "全部任务" : "已归档任务", systemImage: "archivebox") { store.showArchived.toggle() }
                Button("添加连接", systemImage: "link") { store.sheet = .pairing }
                Button("设置", systemImage: "gearshape") { store.sheet = .settings }
            }
            if store.isReferenceMode {
                Section("剩余用量") { Text("本周 59%").foregroundStyle(.secondary) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
        }.tint(.primary).accessibilityLabel("远程菜单").accessibilityIdentifier("home.menu")
    }

    private func computerLabel(_ profile: ConnectionProfile) -> String {
        guard store.profiles.filter({ $0.name == profile.name }).count > 1 else { return profile.name }
        let detail = profile.relayWorkspaceKey?.split(separator: "/").last.map(String.init) ?? profile.baseURL
        return "\(profile.name) · \(detail)"
    }

    private var connectionEmptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 22) {
                Text("\(store.connection.label) · \(store.hostName)").font(.system(size: 20))
                Text(store.connection == .connecting ? "正在加载这台电脑的任务…" : "请确保 ZCode 正在这台电脑上运行。")
                    .font(.system(size: 19)).multilineTextAlignment(.center)
                if store.activeProfile != nil {
                    Button {
                        if store.activeProfile?.isRelay == true { confirmRelayReconnect = true }
                        else { Task { await store.refresh() } }
                    } label: {
                        if store.connection == .connecting { ProgressView().frame(width: 78, height: 26) }
                        else { Text("重新连接").frame(width: 78, height: 26) }
                    }.buttonStyle(NativeGlassButtonStyle()).disabled(store.connection == .connecting)
                } else {
                    Button("添加连接") { store.sheet = .pairing }
                        .buttonStyle(NativeGlassButtonStyle()).controlSize(.large)
                    if !store.referenceReview {
                        Button("先体验界面") { store.enterReferenceMode() }.font(.subheadline)
                    }
                }
            }.foregroundStyle(.secondary).padding(.horizontal, 28)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func groupTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if (calendar.dateComponents([.day], from: date, to: .now).day ?? 100) < 7 { return "过去 7 天" }
        return "更早"
    }
}
