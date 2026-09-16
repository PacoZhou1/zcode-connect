import Foundation

enum ReferenceData {
    #if DEBUG
    /// Isolated presentation fixture; no remote task or model is invoked.
    static var transcriptReviewMessages: [ChatMessage] {
        [
            ChatMessage(id: "review-input", role: .user, text: "检查这个项目的完成情况",
                        transcript: .init(turnID: "review-completed", state: .completed, role: .input)),
            ChatMessage(id: "review-progress", role: .assistant, text: "我先核对源码和测试记录。",
                        steps: [.init(id: "review-tool", title: "读取项目文件", detail: "示例检查记录", status: .completed)],
                        reasoning: "先检查可复现的验证结果。",
                        transcript: .init(turnID: "review-completed", state: .completed, role: .process)),
            ChatMessage(id: "review-final", role: .assistant, text: "检查完成。连接与任务列表已经恢复，下一步核对真机上的交互。",
                        transcript: .init(turnID: "review-completed", state: .completed, role: .finalAnswer)),
            ChatMessage(id: "review-next-input", role: .user, text: "继续检查性能",
                        transcript: .init(turnID: "review-running", state: .running, role: .input)),
            ChatMessage(id: "review-next-progress", role: .assistant, text: "正在检查滚动时的更新频率。",
                        steps: [.init(id: "review-live-tool", title: "分析更新记录", detail: "示例运行中的过程", status: .running)],
                        isStreaming: true,
                        transcript: .init(turnID: "review-running", state: .running, role: .process))
        ]
    }
    /// Fabricated review data only; the reference transport cannot grant host trust.
    static func hookReviewInteraction(expired: Bool = false) throws -> PendingInteraction {
        let now = Date.now.timeIntervalSince1970 * 1000
        let raw = """
        {"kind":"workspaceHookReview","reviewFlowId":"reference-hook-flow","generation":1,
        "interactionId":"reference-hook-review","sessionId":"reference-architecture","taskId":"reference-hook-task",
        "runId":"reference-hook-run","workspaceIdentity":"reference-workspace","workspaceLabel":"审查体验 · 示例工作区",
        "bundleDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","createdAt":\(now - 2000),"deadlineAt":\(expired ? now - 1000 : now + 600000),
        "sourceFiles":[{"path":"/example/.zcode/hooks.json","displayPath":".zcode/hooks.json","editable":true}],
        "summary":{"eventCount":2,"hookCount":2,"pendingCount":1},
        "items":[{"reviewItemId":"reference-hook-check","event":"UserPromptSubmit","type":"command",
        "displayName":"示例检查","displayCommand":"printf 'review fixture'","sourcePath":".zcode/hooks.json",
        "resolvedTimeoutMs":1000,"resolvedMaxOutputBytes":4096,"executionMode":"foreground","configuredEnabled":true,"editable":true,"trustState":"pending_trust"},
        {"reviewItemId":"reference-hook-report","event":"PostToolUse","matcher":"Read","type":"command",
        "displayName":"示例报告","displayCommand":"printf 'report fixture'","sourcePath":".zcode/hooks.json",
        "resolvedTimeoutMs":1000,"resolvedMaxOutputBytes":4096,"executionMode":"background","configuredEnabled":false,"editable":true,"trustState":"trusted_persistent"}],
        "warningCode":"workspace_hooks_execute_code"}
        """
        let review = try JSONDecoder().decode(RelayHookReviewRequest.self, from: Data(raw.utf8))
        return PendingInteraction(id: review.interactionId, sessionId: review.sessionId,
            kind: "workspaceHookReview", title: "审查体验 · 工作区命令", hookReview: review)
    }
    #endif
    static let project = RemoteProject(id: "reference-project", name: "示例项目", path: "/example/project")
    static let projects = [project, RemoteProject(id: "reference-second", name: "另一个项目", path: "/example/second")]
    static let conversationID = "reference-architecture"
    static var sessions: [RemoteSession] {
        ["检查项目", "介绍项目结构", "整理文档", "检查界面"].enumerated().map { i, title in
            RemoteSession(id: i == 1 ? conversationID : "reference-\(i)", title: title,
                          projectID: project.id, projectName: project.name, updatedAt: .now,
                          status: .completed, canControl: true)
        }
    }
    static let goal = TaskGoal(text: "完成项目检查并总结结果", isPaused: true, elapsed: "3分钟")
    static let agents = (1...4).map { AgentTask(id: "example-agent-\($0)", title: "示例检查 \($0)", status: .completed, detail: "此内容仅用于界面体验。", colorIndex: $0 - 1) }
    static let longUserText = "请介绍这个项目的结构，并说明如何开始。"
    static var messages: [ChatMessage] {
        [ChatMessage(id: "ref-user-1", role: .user, text: longUserText),
         ChatMessage(id: "ref-assistant-1", role: .assistant, text: "这是界面体验数据。连接你的电脑后，这里会显示真实任务和回复。")]
    }
    static let files = [RemoteFile(name: "README.md", path: "README.md", isDirectory: false, content: "# 示例项目")]
    static var homePreviewMessages: [ChatMessage] { messages }
}
