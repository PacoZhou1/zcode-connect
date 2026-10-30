import Foundation

/// Synthetic data used by the in-app App Store review demo and by Debug visual checks.
/// It contains no desktop paths, credentials, customer content, or live task data.
enum ReferenceData {
    #if DEBUG
    static var transcriptReviewMessages: [ChatMessage] {
        [
            ChatMessage(id: "review-input", role: .user, text: L10n.tr("检查示例任务的状态"), transcript: .init(turnID: "review-completed", state: .completed, role: .input)),
            ChatMessage(id: "review-progress", role: .assistant, text: L10n.tr("正在读取示例工作区的记录。"), steps: [.init(id: "review-tool", title: L10n.tr("读取任务"), detail: L10n.tr("示例数据"), status: .completed)], reasoning: L10n.tr("演示任务不会连接电脑。"), transcript: .init(turnID: "review-completed", state: .completed, role: .process)),
            ChatMessage(id: "review-final", role: .assistant, text: L10n.tr("示例检查完成。连接真实电脑后可查看你自己的任务。"), transcript: .init(turnID: "review-completed", state: .completed, role: .finalAnswer))
        ]
    }

    static func hookReviewInteraction(expired: Bool = false) throws -> PendingInteraction {
        let now = Date.now.timeIntervalSince1970 * 1000
        let raw = """
        {"kind":"workspaceHookReview","reviewFlowId":"demo-hook-flow","generation":1,"interactionId":"demo-hook-review","sessionId":"demo-session","taskId":"demo-hook-task","runId":"demo-hook-run","workspaceIdentity":"demo-workspace","workspaceLabel":"\(L10n.tr("示例工作区"))","bundleDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","createdAt":\(now - 2000),"deadlineAt":\(expired ? now - 1000 : now + 600000),"sourceFiles":[{"path":".zcode/hooks.json","displayPath":".zcode/hooks.json","editable":false}],"summary":{"eventCount":1,"hookCount":1,"pendingCount":1},"items":[{"reviewItemId":"demo-hook-check","event":"UserPromptSubmit","type":"command","displayName":"\(L10n.tr("示例检查"))","displayCommand":"printf 'demo only'","sourcePath":".zcode/hooks.json","resolvedTimeoutMs":1000,"resolvedMaxOutputBytes":4096,"executionMode":"foreground","configuredEnabled":true,"editable":false,"trustState":"pending_trust"}],"warningCode":"workspace_hooks_execute_code"}
        """
        let review = try JSONDecoder().decode(RelayHookReviewRequest.self, from: Data(raw.utf8))
        return PendingInteraction(id: review.interactionId, sessionId: review.sessionId, kind: "workspaceHookReview", title: L10n.tr("示例工作区命令"), hookReview: review)
    }
    #endif

    static var project: RemoteProject { RemoteProject(id: "demo-project", name: L10n.tr("示例工作区"), path: L10n.tr("示例工作区")) }
    static var projects: [RemoteProject] { [project] }
    static let conversationID = "demo-session"
    static var sessions: [RemoteSession] {
        [
            RemoteSession(id: conversationID, title: L10n.tr("整理发布说明"), projectID: project.id, projectName: project.name, updatedAt: .now, status: .completed, isPinned: true, canControl: true),
            RemoteSession(id: "demo-running", title: L10n.tr("检查任务进度"), projectID: project.id, projectName: project.name, updatedAt: .now.addingTimeInterval(-3_600), status: .running, canControl: true),
            RemoteSession(id: "demo-waiting", title: L10n.tr("等待确认的操作"), projectID: project.id, projectName: project.name, updatedAt: .now.addingTimeInterval(-86_400), status: .waiting, canControl: true)
        ]
    }
    static var goal: TaskGoal { TaskGoal(text: L10n.tr("这是应用内演示任务。连接你自己的 ZCode 桌面端后，内容将替换为你的任务。"), isPaused: false, elapsed: L10n.tr("2 分钟")) }
    static var agents: [AgentTask] { [
        AgentTask(id: "demo-agent-1", title: L10n.tr("汇总任务状态"), status: .completed, detail: L10n.tr("示例数据，不会访问电脑。"), colorIndex: 0),
        AgentTask(id: "demo-agent-2", title: L10n.tr("准备下一步"), status: .running, detail: L10n.tr("示例中的进行中任务。"), colorIndex: 1)
    ] }
    static var messages: [ChatMessage] {
        [
            ChatMessage(id: "demo-user", role: .user, text: L10n.tr("请整理这次发布的重点。")),
            ChatMessage(id: "demo-process", role: .assistant, text: L10n.tr("正在整理示例任务。"), steps: [.init(id: "demo-read", title: L10n.tr("读取任务"), detail: L10n.tr("示例工作区"), status: .completed)]),
            ChatMessage(id: "demo-answer", role: .assistant, text: L10n.tr("已整理完成。连接你的电脑后，你可以在这里阅读任务、继续对话，并处理需要确认的操作。"), elapsed: L10n.tr("12 秒"), changes: [FileChange(path: L10n.tr("发布说明.md"), additions: 3, deletions: 0, diff: L10n.tr("+ 支持移动端查看任务\n+ 支持继续对话\n+ 支持完成提醒"))])
        ].map { message in
            var value = message
            value.transcript = .init(turnID: "demo-turn", state: .completed, role: message.role == .user ? .input : .finalAnswer)
            return value
        }
    }
    static var files: [RemoteFile] { [
        RemoteFile(name: "README.md", path: "README.md", isDirectory: false, content: L10n.tr("# 示例工作区\n\n此内容仅用于应用内演示。")),
        RemoteFile(name: L10n.tr("发布说明.md"), path: L10n.tr("发布说明.md"), isDirectory: false, content: L10n.tr("# 发布说明\n\n连接真实工作区后可查看你的文件。"))
    ] }
    static var homePreviewMessages: [ChatMessage] { messages }
}
