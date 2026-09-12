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
    @State private var position = ScrollPosition(edge: .bottom)

    private var session: RemoteSession? { store.session(sessionID) }

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
                                     text: "此任务由电脑上的 ZCode 管理。你可以查看记录，或新建一个手机可控制的任务。")
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
                            let anchor = store.messages(sessionID).first?.id
                            showJump = true
                            Task {
                                await store.loadEarlierMessages(sessionID)
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
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
                    ForEach(store.messages(sessionID)) { message in
                        MessageView(message: message, sessionID: sessionID).padding(.bottom, message.role == .user ? 34 : 22).id(message.id)
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
                if !showJump && !userScrolling { position.scrollTo(edge: .bottom) }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, atBottom in
                if userScrolling || atBottom { showJump = !atBottom }
            }
            .onScrollPhaseChange { _, phase in
                #if DEBUG
                if MotionPerformanceProbe.shared.isRunning { MotionPerformanceProbe.shared.setStage("chat-\(phase)") }
                #endif
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .simultaneousGesture(TapGesture().onEnded { dismissOverlaysSignal += 1 })
            .accessibilityIdentifier("chat.transcript")
            .overlay(alignment: .bottom) {
                if showJump {
                    Button {
                        withAnimation { position.scrollTo(edge: .bottom) }
                        showJump = false
                    } label: { Image(systemName: "arrow.down").font(.system(size: 21, weight: .medium)).frame(width: 24, height: 24) }
                        .buttonStyle(NativeGlassButtonStyle()).buttonBorderShape(.circle)
                        .padding(.bottom, 8).accessibilityLabel("跳到最新消息")
                }
            }
            .onChange(of: store.messages(sessionID).last?.id) { _, _ in
                if !showJump && !userScrolling { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: store.messages(sessionID).last?.text.count) { _, _ in
                if !showJump && !userScrolling { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: store.pendingInteractions[sessionID]?.count) { _, _ in
                if !showJump && !userScrolling { position.scrollTo(edge: .bottom) }
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
                        showJump = true
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

    private var threadMenu: some View {
        Menu {
            Section(session?.title ?? "任务") {
                Button(session?.isPinned == true ? "取消置顶" : "置顶",
                       systemImage: session?.isPinned == true ? "pin.slash" : "pin") { store.togglePin(sessionID) }
                Button("重命名", systemImage: "pencil") {
                    renameText = session?.title ?? ""
                    renamePresented = true
                }
                if store.isReferenceMode || session?.canFork == true {
                    Button(store.isForking(sessionID) ? "正在创建分支…" : "创建分支", systemImage: "arrow.triangle.branch") { store.forkSession(sessionID) }
                        .disabled(store.isForking(sessionID) || session?.isArchived == true)
                        .accessibilityIdentifier("chat.fork")
                }
                Button("复制对话串 ID", systemImage: "square.on.square") { store.copy(sessionID) }
                Button(session?.isArchived == true ? "取消归档" : "归档", systemImage: "archivebox", role: session?.isArchived == true ? nil : .destructive) { store.archive(sessionID, archived: session?.isArchived != true) }
            }
            Section {
                Button("更改", systemImage: "point.3.connected.trianglepath.dotted") { store.sheet = .files(sessionID, true) }
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
