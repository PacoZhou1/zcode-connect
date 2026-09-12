import SwiftUI

struct WorkspaceHookReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let sessionID: String
    let interactionID: String
    @State private var selected: Set<String> = []
    @State private var proposedAction: WorkspaceHookReviewAction?
    @State private var confirmedRequest: RelayHookReviewRequest?
    @State private var activeSubmission: UUID?
    @State private var resultMessage: String?
    @State private var reviewExpired = false
    @State private var proposedRevision: String?
    @State private var proposedGeneration: UUID?

    private var request: RelayHookReviewRequest? {
        store.pendingInteractions[sessionID]?.first { $0.id == interactionID }?.hookReview
    }
    private var scope: String {
        "\(store.activeProfileID ?? "")|\(store.activeProfile?.baseURL ?? "")|\(store.hookReviewGeneration)|\(store.connection.isOnline)"
    }
    private var revision: String {
        guard let request else { return scope + "|settled" }
        return "\(scope)|\(request.fingerprint)"
    }
    private var busy: Bool { activeSubmission != nil }
    private var canInteract: Bool { !busy && !reviewExpired && store.connection.isOnline }

    var body: some View {
        NavigationStack {
            Group {
                if let request {
                    List {
                        Section {
                            Text(request.workspaceLabel).font(.headline)
                            if !store.connection.isOnline {
                                Label("连接已断开，请重新连接后查看最新审查。", systemImage: "wifi.exclamationmark")
                                    .foregroundStyle(.orange)
                            }
                            Label("这些命令会在电脑上运行", systemImage: "terminal")
                            Text("信任后，所选命令可在此工作区自动执行，无需每次批准。信任会保留到你撤销或命令声明发生变化。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if reviewExpired {
                                Label("本次审查已过期，请在电脑端重新发起。", systemImage: "clock.badge.exclamationmark")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Section("配置来源") {
                            ForEach(request.sourceFiles, id: \.path) { source in
                                Text(source.displayPath).font(.footnote).textSelection(.enabled)
                            }
                        }
                        Section("逐项审查") {
                            ForEach(request.items, id: \.reviewItemId) { item in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top) {
                                        if ["pending_trust", "revoked", "stale_digest"].contains(item.trustState) {
                                            Button {
                                                if selected.contains(item.reviewItemId) { selected.remove(item.reviewItemId) }
                                                else { selected.insert(item.reviewItemId) }
                                            } label: {
                                                Image(systemName: selected.contains(item.reviewItemId) ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3)
                                            }.buttonStyle(.borderless)
                                                .accessibilityLabel("选择信任：\(item.displayName)")
                                                .accessibilityValue(selected.contains(item.reviewItemId) ? "已选择" : "未选择")
                                                .disabled(!canInteract)
                                        }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.displayName).font(.headline)
                                            Text(trustLabel(item.trustState)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(item.displayCommand).font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    LabeledContent("触发时机", value: eventLabel(item.event))
                                    if let matcher = item.matcher, !matcher.isEmpty { LabeledContent("匹配条件", value: matcher) }
                                    LabeledContent("运行方式", value: item.executionMode == "background" ? "后台" : "前台")
                                    LabeledContent("类型", value: item.type == "process" ? "进程" : "命令")
                                    LabeledContent("最长运行", value: "\(item.resolvedTimeoutMs) 毫秒")
                                    LabeledContent("输出上限", value: "\(item.resolvedMaxOutputBytes) 字节")
                                    Text(item.sourcePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    HStack {
                                        Label(item.configuredEnabled ? "已启用" : "已停用", systemImage: item.configuredEnabled ? "checkmark.circle" : "minus.circle")
                                        Spacer()
                                        if item.editable {
                                            Button(item.configuredEnabled ? "停用" : "启用") {
                                                propose(.setEnabled(item.reviewItemId, !item.configuredEnabled), request: request)
                                            }.buttonStyle(.borderless)
                                                .disabled(!canInteract)
                                        }
                                        if item.trustState == "trusted_persistent" {
                                            Button("撤销信任", role: .destructive) { propose(.revoke([item.reviewItemId]), request: request) }
                                                .buttonStyle(.borderless)
                                                .disabled(!canInteract)
                                        }
                                    }
                                }.font(.footnote).padding(.vertical, 6)
                            }
                        }
                        if let resultMessage { Section { Text(resultMessage).font(.footnote).foregroundStyle(.secondary) } }
                        Section {
                            Button {
                                propose(.trust(selected.sorted()), request: request)
                            } label: {
                                HStack {
                                    Text("信任所选 \(selected.count) 项")
                                    Spacer()
                                    if busy { ProgressView() }
                                }
                            }.disabled(selected.isEmpty || !canInteract)
                                .accessibilityIdentifier("hooks.trustSelected")
                            Text("关闭此页面不会批准或拒绝这些命令。你也可以回到电脑端处理。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("本次审查已结束", systemImage: "checkmark.shield",
                        description: Text("请求已处理、更新或连接已切换。返回会话查看电脑的最新状态。"))
                }
            }
            .navigationTitle("工作区命令审查").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新") { refresh() }.disabled(busy || !store.connection.isOnline)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .confirmationDialog(confirmationTitle, isPresented: Binding(get: { proposedAction != nil }, set: { if !$0 { proposedAction = nil; confirmedRequest = nil } }), titleVisibility: .visible) {
                Button(confirmationButton, role: isRevocation ? .destructive : nil) { submit() }
                Button("取消", role: .cancel) { proposedAction = nil; confirmedRequest = nil }
            } message: { Text(confirmationMessage) }
            .onChange(of: revision) { _, _ in
                selected = []; proposedAction = nil; confirmedRequest = nil; resultMessage = nil; activeSubmission = nil
            }
            .onChange(of: request) { _, _ in
                selected = []; proposedAction = nil; confirmedRequest = nil; resultMessage = nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, let request, Date.now.timeIntervalSince1970 * 1000 >= request.deadlineAt {
                    reviewExpired = true; selected = []; proposedAction = nil; confirmedRequest = nil
                }
            }
            .task(id: revision) {
                guard let request else { reviewExpired = true; return }
                let remaining = Double(request.deadlineAt) / 1000 - Date.now.timeIntervalSince1970
                reviewExpired = remaining <= 0
                guard remaining > 0 else { return }
                do {
                    try await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                    reviewExpired = true; proposedAction = nil; confirmedRequest = nil; selected = []
                } catch {}
            }
        }
    }

    private func propose(_ action: WorkspaceHookReviewAction, request: RelayHookReviewRequest) {
        guard !busy, store.connection.isOnline, Date.now.timeIntervalSince1970 * 1000 < Double(request.deadlineAt) else { return }
        confirmedRequest = request
        proposedRevision = revision
        proposedGeneration = store.hookReviewGeneration
        proposedAction = action
    }
    private func submit() {
        guard let action = proposedAction, let original = confirmedRequest, let generation = proposedGeneration,
              request == original, proposedRevision == revision, generation == store.hookReviewGeneration else {
            proposedAction = nil; confirmedRequest = nil; selected = []; return
        }
        let originalRevision = revision
        let submission = UUID()
        proposedAction = nil; confirmedRequest = nil; activeSubmission = submission; resultMessage = nil
        Task {
            let accepted = await store.performHookReview(original, action: action, expectedGeneration: generation) { message in
                guard activeSubmission == submission, generation == store.hookReviewGeneration else { return }
                resultMessage = message
            }
            guard activeSubmission == submission else { return }
            activeSubmission = nil
            guard revision == originalRevision else { return }
            if accepted {
                selected = []
                resultMessage = resultMessage.map { "电脑已接收这项操作，但刷新状态失败：\($0)" }
                    ?? "电脑已接收这项操作。若列表尚未更新，请点刷新重新读取状态。"
            } else if resultMessage == nil {
                resultMessage = "电脑尚未确认这项操作。请刷新状态后重试。"
            }
        }
    }
    private func refresh() {
        guard !busy, store.connection.isOnline else { return }
        let submission = UUID(), generation = store.hookReviewGeneration
        activeSubmission = submission
        resultMessage = nil
        Task {
            guard activeSubmission == submission, generation == store.hookReviewGeneration else { return }
            await store.loadTranscript(sessionID) { message in
                guard activeSubmission == submission, generation == store.hookReviewGeneration else { return }
                resultMessage = message
            }
            guard activeSubmission == submission, generation == store.hookReviewGeneration else { return }
            activeSubmission = nil
        }
    }
    private var isRevocation: Bool { if case .revoke = proposedAction { return true }; return false }
    private var confirmationTitle: String {
        switch proposedAction {
        case .trust: return "持久信任所选命令？"
        case .revoke: return "撤销所选命令的信任？"
        case .setEnabled(_, let enabled): return enabled ? "启用这个命令？" : "停用这个命令？"
        case nil: return "确认操作"
        }
    }
    private var confirmationButton: String {
        switch proposedAction {
        case .trust: return "确认持久信任"
        case .revoke: return "撤销信任"
        case .setEnabled(_, let enabled): return enabled ? "启用" : "停用"
        case nil: return "确认"
        }
    }
    private var confirmationMessage: String {
        switch proposedAction {
        case .trust(let ids):
            let names = confirmedRequest?.items.filter { ids.contains($0.reviewItemId) }.map(\.displayName).joined(separator: "、") ?? ""
            return "将信任 \(names)。这些命令以后可在此工作区自动执行，无需每次批准。"
        case .revoke: return "这会撤销所选命令声明的持久信任。不会终止已经运行的命令。"
        case .setEnabled: return "这会修改电脑上的工作区配置，并刷新本次审查。启用并不等于授予信任。"
        case nil: return ""
        }
    }
    private func trustLabel(_ state: String) -> String {
        switch state {
        case "pending_trust": "等待信任"
        case "trusted_persistent": "已持久信任"
        case "blocked_untrusted": "尚未信任，已阻止"
        case "blocked_policy": "已被主机策略阻止"
        case "revoked": "已撤销信任"
        case "stale_digest": "命令已变更，需要重新审查"
        default: "无需信任"
        }
    }
    private func eventLabel(_ event: String) -> String {
        switch event {
        case "SessionStart": "会话开始时"
        case "UserPromptSubmit": "提交消息时"
        case "PreToolUse": "工具运行前"
        case "PermissionRequest": "请求权限时"
        case "PostToolUse": "工具运行成功后"
        case "PostToolUseFailure": "工具运行失败后"
        case "Stop": "任务停止时"
        default: event
        }
    }
}
