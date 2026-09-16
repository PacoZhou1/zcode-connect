import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    @State private var dismissOverlaysSignal = 0
    @State private var renamePresented = false
    @State private var renameText = ""
    @State private var showJump = false
    @State private var didInitialScroll = false
    @State private var pendingHistoryAnchor: String?
    @State private var hasUserNavigated = false
    @State private var nearHistoryTop = false
    @State private var historyArmed = true
    @State private var historyLoadRevision = 0
    @State private var readableHeight: CGFloat = 0
    @State private var keepSentBubble = false
    @State private var reserveReplySpace = false
    @State private var followsBottom = true
    // The transcript extends beneath the floating controls; the controls' top edge
    // sizes the table's bottom inset so resting content stays readable above them.
    @State private var controlsTopEdge: CGFloat = 0
    private var screenBottom: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.bounds.height ?? UIScreen.main.bounds.height
    }
    private var bottomCoverage: CGFloat { max(0, screenBottom - controlsTopEdge) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var latestBubbleID: String? {
        if let outgoing = store.outgoingMessages[sessionID], store.messages(sessionID).contains(where: { $0.id == outgoing.id }) { return outgoing.id }
        if let queued = store.queuedInputs[sessionID]?.last { return "queued-bubble:" + queued.id }
        return store.messages(sessionID).last(where: { $0.role == .user })?.id
    }

    private var session: RemoteSession? { store.session(sessionID) }
    @State private var turns: [TranscriptTurn] = []

    private var transcriptHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
                    if !store.isReferenceMode && !store.streamConnected {
                        InlineNotice(symbol: "wifi.exclamationmark", text: "实时连接正在恢复，已显示的内容可能不是最新状态。")
                    }
                    if store.cachedTranscriptIDs.contains(sessionID) {
                        InlineNotice(text: "已显示缓存记录，正在与电脑同步。")
                    }
                    if let message = store.transcriptLoadErrors[sessionID] {
                        HStack {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            Button("重试") { Task { await store.loadTranscript(sessionID); await store.loadSettings(sessionID) } }
                        }.padding(.vertical, 8)
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
                        if store.isLoading || store.transcriptLoading.contains(sessionID) { ProgressView().frame(maxWidth: .infinity).padding(.top, 70) }
                        else {
                            Text(session?.source == "official-relay-subagent" ? "尚未获取到此智能体的记录。" : "从这里继续你的工作。")
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 80)
                        }
                    }
                    if store.histories[sessionID]?.hasMore == true {
                        HStack(spacing: 8) {
                            if store.loadingHistory.contains(sessionID) { ProgressView() }
                            Text(store.loadingHistory.contains(sessionID) ? "正在加载更早的消息…" : "继续上滑查看更早的消息")
                        }.font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .accessibilityIdentifier("chat.loadEarlier")
                    }
        }
    }
    @State private var listCommand: TranscriptListCommand?
    private var listRows: [TranscriptListRow] {
        var result: [TranscriptListRow] = []
        let headerState = "\(store.streamConnected)|\(store.cachedTranscriptIDs.contains(sessionID))|\(store.transcriptLoadErrors[sessionID] ?? "")|\(store.histories[sessionID]?.hasMore ?? false)|\(store.loadingHistory.contains(sessionID))|\(store.messages(sessionID).isEmpty)|\(session?.isArchived ?? false)"
        result.append(.init(id: "transcript-header", revision: headerState.hashValue, content: AnyView(transcriptHeader.environment(store))))
        result += turns.map { turn in
            let content = TranscriptTurnView(turn: turn, sessionID: sessionID, allowsAutoCollapse: followsBottom || keepSentBubble)
                .frame(minHeight: turnReadingHeight(turn.id), alignment: .top)
                .environment(store)
            return .init(id: turn.id, revision: turn.hashValue ^ turnReadingHeight(turn.id).hashValue ^ (followsBottom || keepSentBubble).hashValue, content: AnyView(content))
        }
        result += (store.queuedInputs[sessionID] ?? []).map { item in
            .init(id: "queued-bubble:" + item.id, revision: String(describing: item).hashValue ^ queueReadingHeight(item.id).hashValue,
                  content: AnyView(queuedBubble(item).environment(store)))
        }
        result += (store.pendingInteractions[sessionID] ?? []).map { item in
            .init(id: "interaction:" + item.id, revision: String(describing: item).hashValue,
                  content: AnyView(InteractionRequestCard(interaction: item).padding(.bottom, 28).environment(store)))
        }
        return result
    }
    private func issueScrollToLatest() {
        listCommand = .init(id: UUID(), target: nil, bottom: true)
    }
    private func issueScrollToSent() {
        guard let bubble = latestBubbleID else { return }
        let target = turns.last(where: { $0.userMessages.contains(where: { $0.id == bubble }) })?.id ?? bubble
        listCommand = .init(id: UUID(), target: target, bottom: false)
    }

    private func scrollingTranscript(_ proxy: ScrollViewProxy) -> some View {
        StableTranscriptList(rows: listRows, command: listCommand, followsBottom: followsBottom, bottomInset: bottomCoverage + 14,
            onViewport: { height, atBottom, nearTop in
                if abs(readableHeight - height) > 0.5 { readableHeight = height }
                showJump = !atBottom
                nearHistoryTop = nearTop
                if !nearTop { historyArmed = true }
            }, onInteraction: { active in
                if active {
                    hasUserNavigated = true
                    followsBottom = false; keepSentBubble = false; reserveReplySpace = false
                    listCommand = nil
                    if !store.loadingHistory.contains(sessionID) { historyArmed = true }
                } else if nearHistoryTop { requestEarlierHistory() }
            })
            .ignoresSafeArea(edges: .bottom)
            .simultaneousGesture(TapGesture().onEnded { dismissOverlaysSignal += 1 })
            .overlay(alignment: .bottom) {
                if showJump || reserveReplySpace {
                    Button {
                        pendingHistoryAnchor = nil; keepSentBubble = false; reserveReplySpace = false
                        followsBottom = true
                        issueScrollToLatest()
                    } label: { Image(systemName: "arrow.down").font(.system(size: 21, weight: .medium)).frame(width: 24, height: 24) }
                        .buttonStyle(NativeGlassButtonStyle()).buttonBorderShape(.circle)
                        // The overlay anchors at the safe-area bottom (the controls' top
                        // edge), so it already tracks panels and keyboard height.
                        .padding(.bottom, 8).accessibilityLabel("跳到最新消息").accessibilityIdentifier("chat.jumpLatest")
                }
            }
            .onChange(of: store.messages(sessionID), initial: true) { _, messages in
                turns = TranscriptPresentation.group(messages)
                if keepSentBubble { issueScrollToSent() }
            }
            .onChange(of: store.sentBubbleFocus[sessionID]) { _, signal in
                if signal != nil { focusSentBubble(); issueScrollToSent() }
            }
            .onChange(of: latestBubbleID) { _, _ in
                if keepSentBubble { issueScrollToSent() }
            }
            .onChange(of: session?.status) { _, status in
                if status == .completed || status == .idle || status == .failed {
                    reserveReplySpace = false; keepSentBubble = false
                }
            }
            .task(id: historyLoadRevision) {
                guard historyLoadRevision > 0, pendingHistoryAnchor != nil else { return }
                await store.loadEarlierMessages(sessionID)
                pendingHistoryAnchor = nil
            }
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollingTranscript(proxy)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConversationControls(sessionID: sessionID, dismissOverlaysSignal: dismissOverlaysSignal)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { controlsTopEdge = $0 }
                    .measureLayout("chat.controls.host")
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
                if store.sentBubbleFocus[sessionID] != nil { focusSentBubble() }
                await store.openTranscript(sessionID)
                if !didInitialScroll && !keepSentBubble && !hasUserNavigated {
                    await Task.yield()
                    if beginsAtReferenceHistory {
                        listCommand = .init(id: UUID(), target: turns.first?.id, bottom: false)
                    } else { followsBottom = true; issueScrollToLatest() }
                    didInitialScroll = true
                }
                #if DEBUG
                if store.isReferenceMode, ProcessInfo.processInfo.arguments.contains("--complete-tools-review") {
                    await store.completeActivityTransitionReview(sessionID)
                }
                if store.isReferenceMode, ProcessInfo.processInfo.arguments.contains("--send-anchor-review") {
                    try? await Task.sleep(for: .seconds(1))
                    _ = await store.send("发送后定位在顶部菜单栏下方", to: sessionID, inputID: "anchor-review-send")
                }
                #endif
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

    private func requestEarlierHistory() {
        guard historyArmed, pendingHistoryAnchor == nil,
              !store.loadingHistory.contains(sessionID),
              store.histories[sessionID]?.hasMore == true,
              let anchor = turns.first?.id else { return }
        historyArmed = false
        pendingHistoryAnchor = anchor
        followsBottom = false
        historyLoadRevision += 1
    }

    private func focusSentBubble() {
        store.sentBubbleFocus[sessionID] = nil
        pendingHistoryAnchor = nil
        followsBottom = false
        keepSentBubble = true
        reserveReplySpace = true
    }

    private func turnReadingHeight(_ id: String) -> CGFloat {
        guard reserveReplySpace, id == turns.last?.id, (store.queuedInputs[sessionID] ?? []).isEmpty else { return 0 }
        return readableHeight
    }

    private func queueReadingHeight(_ id: String) -> CGFloat {
        guard reserveReplySpace, id == store.queuedInputs[sessionID]?.last?.id else { return 0 }
        return readableHeight
    }

    private func queuedBubble(_ item: QueuedInput) -> some View {
                        HStack {
                            Spacer(minLength: 40)
                            VStack(alignment: .trailing, spacing: 12) {
                                HStack(spacing: 5) {
                                    Image(systemName: item.isGuide ? "arrow.turn.down.right" : "text.line.first.and.arrowtriangle.forward")
                                    Text(item.transferPending == true ? "引导待确认" : item.isGuide ? "引导待用" : "排队中")
                                    Menu {
                                        Text(item.text).lineLimit(1)
                                        Button("编辑消息", systemImage: "pencil") { store.editingQueuedInput[sessionID] = item }.disabled(item.transferPending == true)
                                        if !item.isGuide {
                                            Button(item.transferPending == true ? "重试引导" : "改为引导", systemImage: "arrow.turn.down.right") { Task { _ = await store.changeQueuedInput(item, sessionID: sessionID, action: "guide") } }
                                        }
                                        Button("取消消息", systemImage: "trash", role: .destructive) { Task { _ = await store.changeQueuedInput(item, sessionID: sessionID, action: "cancel") } }.disabled(item.transferPending == true)
                                    } label: { Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle()) }
                                    .accessibilityLabel("排队消息菜单").accessibilityIdentifier("queue.menu.\(item.id)")
                                    .disabled(store.queueActions.contains(item.id))
                                }.font(.caption).foregroundStyle(.secondary)
                                RichMessageText(text: item.text, user: true).equatable()
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(ZTheme.userBubble, in: RoundedRectangle(cornerRadius: 23))
                            }
                        }.padding(.vertical, 12)
                            .id("queued-bubble:" + item.id)
                            .frame(minHeight: queueReadingHeight(item.id), alignment: .top)
    }

    private var beginsAtReferenceHistory: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if store.isReferenceMode, let index = args.firstIndex(of: "--screen"), args.indices.contains(index + 1) {
            return ["goal", "agents", "activity-review"].contains(args[index + 1])
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
                Button("模拟器镜像", systemImage: "rectangle.on.rectangle") { store.sheet = .mirror }
                    .accessibilityIdentifier("chat.mirror")
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
            let key = "new:\(store.selectedProjectID ?? "none")"
            if let id = store.pendingSubmissions[key]?.sessionID, let outgoing = store.outgoingMessages[id] {
                ScrollView {
                    MessageView(message: outgoing, sessionID: id).padding(16)
                }.defaultScrollAnchor(.bottom)
            }
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

private struct TranscriptListRow {
    let id: String
    let revision: Int
    let content: AnyView
}
private struct TranscriptListCommand: Equatable {
    let id: UUID
    let target: String?
    let bottom: Bool
}

/// UITableView owns reuse, exact visible-row layout and interactive scrolling.
/// The first visible row + its pixel displacement survives prepend/reconfigure.
private struct StableTranscriptList: UIViewRepresentable {
    let rows: [TranscriptListRow]
    let command: TranscriptListCommand?
    let followsBottom: Bool
    var bottomInset: CGFloat = 14
    let onViewport: (CGFloat, Bool, Bool) -> Void
    let onInteraction: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 180
        table.contentInset = UIEdgeInsets(top: 14, left: 0, bottom: bottomInset, right: 0)
        table.contentInsetAdjustmentBehavior = .never
        table.keyboardDismissMode = .interactive
        table.accessibilityIdentifier = "chat.transcript"
        table.delegate = context.coordinator
        table.register(UITableViewCell.self, forCellReuseIdentifier: "transcript")
        context.coordinator.table = table
        context.coordinator.sizeObservation = table.observe(\.contentSize, options: [.new]) { [weak coordinator = context.coordinator] _, _ in
            Task { @MainActor in coordinator?.contentSizeChanged() }
        }
        context.coordinator.dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) { [weak coordinator = context.coordinator] table, path, id in
            let cell = table.dequeueReusableCell(withIdentifier: "transcript", for: path)
            guard let row = coordinator?.rowMap[id] else { return cell }
            cell.selectionStyle = .none
            cell.backgroundColor = .clear
            cell.contentConfiguration = UIHostingConfiguration { row.content }.minSize(height: 0).margins(.vertical, 0).margins(.horizontal, 16)
            return cell
        }
        return table
    }
    func updateUIView(_ table: UITableView, context: Context) {
        context.coordinator.parent = self
        if abs(table.contentInset.bottom - bottomInset) > 0.25 { table.contentInset.bottom = bottomInset }
        context.coordinator.update(rows: rows, command: command)
    }
    @MainActor final class Coordinator: NSObject, UITableViewDelegate {
        var parent: StableTranscriptList
        weak var table: UITableView?
        var dataSource: UITableViewDiffableDataSource<Int, String>!
        var rowMap: [String: TranscriptListRow] = [:]
        var ids: [String] = []
        var heights: [String: CGFloat] = [:]
        var sizeObservation: NSKeyValueObservation?
        var lastCommand: UUID?
        func contentSizeChanged() {
            guard let table else { return }
            // Only an explicit follow intent may track newly measured content.
            if !applying, parent.followsBottom, !table.isDragging, !table.isDecelerating {
                scrollBottom()
            }
            reportViewport()
        }
        var navigation = 0
        var applying = false
        var needsUpdate = false
        #if DEBUG
        var probeStarted = false
        #endif
        var lastWidth: CGFloat = 0
        var lastViewport: (CGFloat, Bool, Bool)?
        init(_ parent: StableTranscriptList) { self.parent = parent }
        func update(rows: [TranscriptListRow], command: TranscriptListCommand?) {
            guard let table else { return }
            if applying { needsUpdate = true; return }
            if abs(lastWidth - table.bounds.width) > 0.5 { heights = [:]; lastWidth = table.bounds.width }
            let nextIDs = rows.map(\.id)
            let changed = rows.filter { rowMap[$0.id]?.revision != $0.revision }.map(\.id)
            let hasChanges = ids != nextIDs || !changed.isEmpty
            if !hasChanges { execute(command); return }
            let anchor = table.indexPathsForVisibleRows?.sorted().first.flatMap { path -> (String, CGFloat)? in
                guard let id = dataSource.itemIdentifier(for: path) else { return nil }
                return (id, table.rectForRow(at: path).minY - table.contentOffset.y)
            }
            let wasEmpty = ids.isEmpty
            let token = navigation
            rowMap = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            ids = nextIDs
            heights = heights.filter { rowMap[$0.key] != nil }
            for id in changed { heights.removeValue(forKey: id) }
            applying = true
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0]); snapshot.appendItems(nextIDs)
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(changed.filter { existing.contains($0) })
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self, let table = self.table else { return }
                table.layoutIfNeeded()
                self.applying = false
                if token == self.navigation, !table.isDragging, !table.isDecelerating {
                    if self.parent.command?.id != self.lastCommand, self.parent.command != nil {
                        self.execute(self.parent.command)
                    } else if self.parent.followsBottom || wasEmpty {
                        self.scrollBottom()
                    } else if let anchor, let path = self.dataSource.indexPath(for: anchor.0) {
                        let y = table.rectForRow(at: path).minY - anchor.1
                        self.setOffset(y)
                    }
                }
                self.reportViewport()
                #if DEBUG
                if !self.probeStarted, self.ids.count >= 3, ProcessInfo.processInfo.arguments.contains("--scroll-layout-probe") {
                    self.probeStarted = true
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.parent.onInteraction(true)
                        try? await Task.sleep(for: .seconds(2))
                        var rows: [[String: Double]] = []
                        for offset in stride(from: 0, through: 6000, by: 200) {
                            self.setOffset(CGFloat(offset))
                            try? await Task.sleep(for: .milliseconds(180))
                            guard let table = self.table else { return }
                            rows.append(["requested": Double(offset), "actual": table.contentOffset.y, "contentHeight": table.contentSize.height])
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) {
                            try? data.write(to: URL.documentsDirectory.appending(path: "scroll-layout-probe.json"))
                        }
                        if ProcessInfo.processInfo.arguments.contains("--real-scroll-review") {
                            let before = self.ids.count
                            self.setOffset(-14)
                            self.reportViewport()
                            await Task.yield()
                            self.parent.onInteraction(false)
                            try? await Task.sleep(for: .seconds(10))
                            let facts: [String: Int] = ["initialRows": before, "afterTopApproachRows": self.ids.count]
                            if let data = try? JSONSerialization.data(withJSONObject: facts) {
                                try? data.write(to: URL.documentsDirectory.appending(path: "scroll-pagination-probe.json"))
                            }
                        } else { self.parent.onInteraction(false) }
                    }
                }
                #endif
                if self.needsUpdate {
                    self.needsUpdate = false
                    self.update(rows: self.parent.rows, command: self.parent.command)
                }
            }
        }
        func setOffset(_ y: CGFloat) {
            guard let table else { return }
            let minimum = -table.adjustedContentInset.top
            let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            table.setContentOffset(CGPoint(x: 0, y: min(maximum, max(minimum, y))), animated: false)
        }
        func scrollBottom() {
            guard let table, let last = ids.last, let path = dataSource.indexPath(for: last) else { return }
            table.scrollToRow(at: path, at: .bottom, animated: false)
            table.layoutIfNeeded()
            setOffset(table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        }
        func execute(_ command: TranscriptListCommand?) {
            guard let command, command.id != lastCommand, let table, !table.isDragging, !table.isDecelerating else { return }
            if command.bottom { lastCommand = command.id; scrollBottom() }
            else if let target = command.target, let path = dataSource.indexPath(for: target) {
                lastCommand = command.id
                table.scrollToRow(at: path, at: .top, animated: false)
            }
            reportViewport()
        }
        func reportViewport() {
            guard let table else { return }
            let y = table.contentOffset.y + table.adjustedContentInset.top
            let atBottom = table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom >= table.contentSize.height - 80
            // The readable area excludes the region beneath the floating controls.
            let value = (table.bounds.height - table.adjustedContentInset.bottom, atBottom, y < 160)
            if let old = lastViewport, old.0 == value.0, old.1 == value.1, old.2 == value.2 { return }
            lastViewport = value
            DispatchQueue.main.async { [weak self] in self?.parent.onViewport(value.0, value.1, value.2) }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { reportViewport() }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            navigation += 1
            parent.onInteraction(true)
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { reportViewport(); parent.onInteraction(false) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportViewport(); parent.onInteraction(false) }
        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return 180 }
            return heights[id] ?? 180
        }
        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            if let id = dataSource.itemIdentifier(for: indexPath) { heights[id] = cell.bounds.height }
        }
        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            if let id = dataSource.itemIdentifier(for: indexPath) { heights[id] = cell.bounds.height }
        }
    }
}
