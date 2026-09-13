import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    @State private var dismissOverlaysSignal = 0
    @State private var renamePresented = false
    @State private var renameText = ""
    @State private var showJump = false
    @State private var userScrolling = false
    @State private var didInitialScroll = false
    @State private var pendingHistoryAnchor: String?
    @State private var position = ScrollPosition(edge: .bottom)

    private var session: RemoteSession? { store.session(sessionID) }
    private var turns: [TranscriptTurn] { TranscriptPresentation.group(store.messages(sessionID)) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !store.isReferenceMode && !store.streamConnected {
                        InlineNotice(symbol: "wifi.exclamationmark", text: "实时连接正在恢复，已显示的内容可能不是最新状态。")
                    }
                    if store.isReferenceMode && !store.referenceReview {
                        InlineNotice(text: "界面体验 · 此处为参考会话")
                    }
                    if let session, session.isArchived {
                        InlineNotice(symbol: "archivebox", text: "此任务已归档。可在右上角菜单取消归档后继续。")
                    } else if let session, !session.canControl {
                        InlineNotice(symbol: "desktopcomputer",
                                     text: ["bridge-subagent", "official-relay-subagent"].contains(session.source)
                                        ? "此智能体由父任务管理，这里显示电脑上已保存的记录。"
                                        : "此任务由电脑上的 ZCode 管理。你可以查看记录，或新建一个手机可控制的任务。")
                    }
                    if store.messages(sessionID).isEmpty {
                        if store.isLoading { ProgressView().frame(maxWidth: .infinity).padding(.top, 70) }
                        else {
                            Text("从这里继续你的工作。")
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 80)
                        }
                    }
                    if store.histories[sessionID]?.hasMore == true {
                        Button {
                            let anchor = turns.first?.id
                            pendingHistoryAnchor = anchor
                            Task {
                                await store.loadEarlierMessages(sessionID)
                                if turns.first?.id == anchor { pendingHistoryAnchor = nil }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if store.loadingHistory.contains(sessionID) { ProgressView() }
                                Text(store.loadingHistory.contains(sessionID) ? "正在加载…" : "加载更早的消息")
                            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                        .disabled(store.loadingHistory.contains(sessionID))
                        .accessibilityIdentifier("chat.loadEarlier")
                    }
                    ForEach(turns) { turn in
                        TranscriptTurnView(turn: turn, sessionID: sessionID).id(turn.id)
                    }
                    ForEach(store.pendingInteractions[sessionID] ?? []) { interaction in
                        InteractionRequestCard(interaction: interaction).padding(.bottom, 28)
                    }
                    Color.clear.frame(height: 14).id("conversation-bottom")
                }
                .padding(.horizontal, 16).padding(.top, 14)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollPosition($position)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGSize.self) { geometry in
                CGSize(width: geometry.containerSize.height, height: geometry.contentInsets.bottom)
            } action: { _, _ in
                if !showJump && !userScrolling && pendingHistoryAnchor == nil { position.scrollTo(edge: .bottom) }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 80
            } action: { _, atBottom in
                showJump = !atBottom
            }
            .onScrollPhaseChange { _, phase in
                #if DEBUG
                if MotionPerformanceProbe.shared.isRunning { MotionPerformanceProbe.shared.setStage("chat-\(phase)") }
                #endif
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating || phase == .animating
            }
            .simultaneousGesture(TapGesture().onEnded { dismissOverlaysSignal += 1 })
            .accessibilityIdentifier("chat.transcript")
            .overlay(alignment: .bottom) {
                if showJump {
                    Button {
                        pendingHistoryAnchor = nil
                        withAnimation { position.scrollTo(edge: .bottom) }
                    } label: { Image(systemName: "arrow.down").font(.system(size: 21, weight: .medium)).frame(width: 24, height: 24) }
                        .buttonStyle(NativeGlassButtonStyle()).buttonBorderShape(.circle)
                        .padding(.bottom, 8).accessibilityLabel("跳到最新消息")
                }
            }
            .task(id: turns.first?.id) {
                guard let anchor = pendingHistoryAnchor else { return }
                await Task.yield()
                guard !Task.isCancelled, pendingHistoryAnchor == anchor else { return }
                proxy.scrollTo(anchor, anchor: .top)
                pendingHistoryAnchor = nil
            }
            .onChange(of: store.messages(sessionID).last?.id) { _, _ in
                if !showJump && !userScrolling && pendingHistoryAnchor == nil { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: store.messages(sessionID).last?.text) { _, _ in
                if !showJump && !userScrolling && pendingHistoryAnchor == nil { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: store.pendingInteractions[sessionID]?.count) { _, _ in
                if !showJump && !userScrolling && pendingHistoryAnchor == nil { position.scrollTo(edge: .bottom) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConversationControls(sessionID: sessionID, dismissOverlaysSignal: dismissOverlaysSignal)
            }
            .background(ZTheme.background)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session?.title ?? "任务").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("\(session?.projectName ?? "项目") · \(store.hostName)")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { store.path.append(.newSession) } label: {
                        ComposeGlyph().stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).frame(width: 24, height: 24)
                    }.accessibilityLabel("新建聊天").accessibilityIdentifier("chat.new")
                    threadMenu
                }
            }
            .toolbarRole(.editor)
            .navigationBarTitleDisplayMode(.inline)
            .tint(.primary)
            .task {
                await store.loadTranscript(sessionID)
                if !didInitialScroll {
                    await Task.yield()
                    if beginsAtReferenceHistory {
                        position.scrollTo(y: 40)
                    } else { position.scrollTo(edge: .bottom) }
                    didInitialScroll = true
                }
            }
            .alert("重命名任务", isPresented: $renamePresented) {
                TextField("任务名称", text: $renameText).accessibilityIdentifier("rename.field")
                Button("取消", role: .cancel) {}
                Button("保存") { store.rename(sessionID, title: renameText) }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .tint(.primary)
        }
    }

    private var beginsAtReferenceHistory: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if store.isReferenceMode, let index = args.firstIndex(of: "--screen"), args.indices.contains(index + 1) {
            return ["goal", "agents"].contains(args[index + 1])
        }
        #endif
        return false
    }

    private var metadataMenuItems: [SessionMenuItem] {
        guard let session else { return [] }
        return SessionMenuPolicy.items(for: session, isReferenceMode: store.isReferenceMode,
                                       isRelay: store.activeProfile?.isRelay == true,
                                       isOnline: store.connection.isOnline, isUnread: store.isUnread(sessionID))
    }

    private var threadMenu: some View {
        Menu {
            Section(session?.title ?? "任务") {
                if let item = metadataMenuItems.first(where: { $0.id == .pin }) {
                    Button(item.title, systemImage: item.symbol) { store.togglePin(sessionID) }
                        .disabled(!item.isEnabled)
                }
                if let item = metadataMenuItems.first(where: { $0.id == .rename }) {
                    Button(item.title, systemImage: item.symbol) {
                        renameText = session?.title ?? ""
                        renamePresented = true
                    }.disabled(!item.isEnabled)
                }
                if store.isReferenceMode || session?.canFork == true {
                    Button(store.isForking(sessionID) ? "正在创建分支…" : "创建分支", systemImage: "arrow.triangle.branch") { store.forkSession(sessionID) }
                        .disabled(store.isForking(sessionID) || session?.isArchived == true)
                        .accessibilityIdentifier("chat.fork")
                }
                Button("复制对话串 ID", systemImage: "square.on.square") { store.copy(sessionID) }
                if let item = metadataMenuItems.first(where: { $0.id == .archive }) {
                    Button(item.title, systemImage: item.symbol, role: item.destructive ? .destructive : nil) { store.archive(sessionID, archived: session?.isArchived != true) }
                        .disabled(!item.isEnabled)
                }
            }
            Section {
                if !["bridge-subagent", "official-relay-subagent"].contains(session?.source ?? "") {
                    Button("更改", systemImage: "point.3.connected.trianglepath.dotted") { store.sheet = .files(sessionID, true) }
                }
                Button("文件", systemImage: "folder") { store.sheet = .files(sessionID, false) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
        }.accessibilityLabel("任务菜单").accessibilityIdentifier("chat.menu")
    }
}

struct NewSessionView: View {
    @Environment(AppStore.self) private var store
    @State private var dismissOverlaysSignal = 0
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 26.666667) {
                Button { store.sheet = .connections } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "laptopcomputer").frame(width: 24)
                        Text(store.hostName)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                    }
                }.accessibilityIdentifier("new.host")
                Menu {
                    Picker("项目", selection: $store.selectedProjectID) {
                        ForEach(store.projects) { project in Text(project.name).tag(Optional(project.id)) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").frame(width: 24)
                        Text(store.projects.first { $0.id == store.selectedProjectID }?.name ?? "选择项目")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                    }
                }.accessibilityIdentifier("new.project")
            }.font(.system(size: 18)).foregroundStyle(.secondary)
                .padding(.horizontal, 26).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ZTheme.background.onTapGesture { dismissOverlaysSignal += 1 } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(sessionID: nil, initiallyFocused: true, dismissOverlaysSignal: dismissOverlaysSignal)
                .padding(.bottom, 12)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .tint(.primary)
        .task(id: store.selectedProjectID) {
            if let id = store.selectedProjectID { await store.loadProjectSettings(id) }
        }
    }
}
