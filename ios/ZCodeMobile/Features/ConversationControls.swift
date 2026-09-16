import SwiftUI

struct ConversationControls: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    var dismissOverlaysSignal = 0
    @State private var selectedPanel: String?
    @State private var editGoal = false
    @State private var reasoningPresented = false
    @State private var confirmDeleteGoal = false

    var body: some View {
        VStack(spacing: 16) {
            if selectedPanel == "goal" {
                panel("goal")
                    .padding(.horizontal, 38)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if store.goals[sessionID] != nil || store.agentCount(sessionID) > 0 {
                HStack(spacing: 8) {
                    if store.goals[sessionID] != nil {
                        Button { toggle("goal") } label: {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Label { Text("\(store.goalTitle(sessionID))  \(store.goalElapsed(sessionID, at: context.date))") } icon: { TargetArrowGlyph().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 17, height: 17) }
                                    .font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8)
                                    .padding(.horizontal, 12).frame(height: 32)
                            }
                        }.buttonStyle(.plain)
                            .foregroundStyle(selectedPanel == "goal" ? Color.white : .secondary)
                            .glassEffect(ZTheme.controlGlass.tint(selectedPanel == "goal" ? .black : .clear).interactive(), in: Capsule())
                            .accessibilityIdentifier("chat.goal")
                            .measureLayout("goal.pill")
                    }
                    if store.agentCount(sessionID) > 0 {
                        Button { toggle("agents") } label: {
                            Label {
                                Text("\(store.agentCount(sessionID)) 个智能体")
                            } icon: {
                                RobotGlyph().stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                                    .frame(width: 17, height: 17)
                            }
                                .font(.system(size: 13)).padding(.horizontal, 9).frame(height: 32)
                        }.buttonStyle(.plain)
                            .foregroundStyle(selectedPanel == "agents" ? Color.white : .secondary)
                            .glassEffect(ZTheme.controlGlass.tint(selectedPanel == "agents" ? .black : .clear).interactive(), in: Capsule())
                            .accessibilityIdentifier("chat.agents")
                            .measureLayout("agents.pill")
                            .nativeFloatingPanel(isPresented: Binding(
                                get: { selectedPanel == "agents" },
                                set: { if !$0, selectedPanel == "agents" { selectedPanel = nil } }
                            ), preferredWidth: 364) { panel("agents") }
                    }
                }.padding(.horizontal, 42)
                    .blur(radius: reasoningPresented ? 4 : 0)
                    .allowsHitTesting(!reasoningPresented)
            }
            if store.session(sessionID)?.source == "official-relay-subagent" {
                Label("智能体记录 · 由主任务管理", systemImage: "text.bubble")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                ComposerView(sessionID: sessionID, dismissOverlaysSignal: dismissOverlaysSignal, onReasoningVisibilityChange: { reasoningPresented = $0 })
            }
        }
        .padding(.top, 8).padding(.bottom, reasoningPresented ? 0 : 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedPanel)
        .onChange(of: store.goals[sessionID]) { _, goal in
            if goal == nil && selectedPanel == "goal" { selectedPanel = nil }
        }
        .onChange(of: store.agentCount(sessionID)) { _, count in
            if count == 0 && selectedPanel == "agents" { selectedPanel = nil }
        }
        .sheet(isPresented: $editGoal) { GoalEditorView(sessionID: sessionID) }
        .confirmationDialog("移除这个目标？", isPresented: $confirmDeleteGoal, titleVisibility: .visible) {
            Button("移除目标", role: .destructive) {
                guard store.isReferenceMode else { return }
                store.goals[sessionID] = nil; selectedPanel = nil
            }
        } message: { Text("会话内容会保留。") }
        .task {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--screen"), args.indices.contains(i + 1), ["goal", "agents", "agents-review"].contains(args[i + 1]) {
                selectedPanel = args[i + 1] == "agents-review" ? "agents" : args[i + 1]
            }
            #endif
        }
    }

    @ViewBuilder private func panel(_ name: String) -> some View {
        if name == "goal", let goal = store.goals[sessionID] {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(goal.text).font(.system(size: 12)).lineSpacing(2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .measureLayout("goal.text")
                }.frame(maxHeight: 100.333333)
                HStack(spacing: 18) {
                    Spacer()
                    Button { editGoal = true } label: { Image(systemName: "pencil") }.accessibilityLabel("编辑目标")
                        .disabled(!store.canManageGoals)
                    Button {
                        Task { await store.toggleGoal(sessionID) }
                    } label: {
                        if store.changingGoals.contains(sessionID) { ProgressView().controlSize(.small) }
                        else { Image(systemName: goal.isPaused ? "play.circle" : "pause.circle") }
                    }
                        .accessibilityLabel(goal.isPaused ? "继续目标" : "暂停目标")
                        .disabled(!store.canToggleGoal(sessionID))
                    Button { confirmDeleteGoal = true } label: { Image(systemName: "trash") }.accessibilityLabel("移除目标")
                        .disabled(!store.canManageGoals)
                }.font(.system(size: 18)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 8).glassEffect(ZTheme.controlGlass, in: RoundedRectangle(cornerRadius: 17))
                .measureLayout("goal.panel")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(agentGroups, id: \.0) { title, agents in
                            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        ForEach(agents) { agent in
                            Button {
                                if store.isReferenceMode { store.sheet = .agent(agent) }
                                else { selectedPanel = nil; store.openAgent(agent, parentID: sessionID) }
                            } label: {
                                HStack(spacing: 11) {
                                    Circle().fill(ZTheme.agentColors[abs(agent.colorIndex % 4)]).frame(width: 10, height: 10)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.primary).lineLimit(2)
                                        Text(agent.statusText ?? agent.status.label).font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if agent.status == .running { ProgressView().controlSize(.small) }
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        }
                        if !store.isReferenceMode {
                            if let error = store.agentDirectoryError(sessionID) {
                                Text(error).font(.footnote).foregroundStyle(.secondary)
                                Button("重试") { Task { await store.refreshAgents(sessionID) } }
                            }
                            if store.loadingAgentDirectories.contains(sessionID) { ProgressView() }
                            else if store.hostAgents[sessionID]?.nextEndedCursor != nil {
                                Button("加载更多智能体") { Task { await store.refreshAgents(sessionID, loadMore: true) } }
                                    .accessibilityIdentifier("agents.loadMore")
                            }
                        }
                        if !store.isReferenceMode && (store.agentTasks[sessionID] ?? []).isEmpty {
                            Text("主机记录了 \(store.agentCount(sessionID)) 个智能体，正在等待任务详情。")
                                .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                    }
                }.frame(height: agentListHeight)
            }.padding(12)
                .measureLayout("agents.panel")
                .task { await store.refreshAgents(sessionID) }
        }
    }
    private var agentGroups: [(String, [AgentTask])] {
        let all = store.agentTasks[sessionID] ?? []
        return [("进行中", all.filter { $0.status == .running }),
                ("等待中", all.filter { $0.status == .waiting }),
                ("已完成", all.filter { $0.status == .completed }),
                ("失败", all.filter { $0.status == .failed }),
                ("其他", all.filter { ![SessionStatus.running, .waiting, .completed, .failed].contains($0.status) })]
            .filter { !$0.1.isEmpty }
    }
    private var agentListHeight: CGFloat {
        let count = min(4, (store.agentTasks[sessionID] ?? []).count)
        return count == 0 ? 64 : min(300, CGFloat(count * 44 + max(0, count - 1) * 6 + agentGroups.count * 30))
    }

    private func toggle(_ panel: String) {
        store.haptic()
        selectedPanel = selectedPanel == panel ? nil : panel
    }
}

struct GoalEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: String?
    @State private var goalText = ""
    @State private var submitting = false
    @State private var failure: String?
    @State private var submission: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section("你希望完成什么？") {
                    TextEditor(text: $goalText).frame(minHeight: 160)
                        .disabled(submitting).accessibilityIdentifier("goal.editor")
                }
                Section {
                    Text("电脑会围绕这个目标持续工作。开始后可查看进度、暂停或继续；电脑需要保持联网。")
                        .foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red).accessibilityIdentifier("goal.error") }
                }
            }
            .navigationTitle("追求目标").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { submission?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !submitting else { return }
                        submitting = true; failure = nil
                        submission = Task {
                            do {
                                try await store.startGoal(goalText, sessionID: sessionID)
                                guard !Task.isCancelled else { return }
                                submitting = false; dismiss()
                            } catch {
                                guard !Task.isCancelled else { return }
                                submitting = false; failure = error.localizedDescription
                            }
                        }
                    } label: {
                        if submitting { ProgressView() }
                        else { Text(store.isReferenceMode ? "保存" : "开始") }
                    }.disabled(submitting || goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canStartGoal(sessionID))
                        .accessibilityIdentifier("goal.start")
                }
            }
        }
        .task { goalText = store.pendingGoalText(sessionID) ?? sessionID.flatMap { store.goals[$0]?.text } ?? "" }
        .onDisappear { submission?.cancel() }
    }
}

struct AgentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let agent: AgentTask
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(agent.statusText ?? agent.status.label, systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text(agent.detail).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.navigationTitle(agent.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
