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
    // Entirely fictional presentation data. Never copied from a user's workspace.
    static let project = RemoteProject(id: "reference-project", name: "Demo Workspace", path: "/example/workspace")
    static let projects = [
        project,
        RemoteProject(id: "reference-mobile", name: "示例移动应用", path: "/example/mobile-app")
    ]
    static let conversationID = "reference-architecture"
    static var sessions: [RemoteSession] {
        let titles = [
            "登录页深色模式", "整理项目结构", "检查连接状态", "示例移动应用",
            "设计设置页面", "改进文件列表", "检查任务恢复",
            "整理产品说明", "优化对话排版", "准备发布清单", "更新应用图标"
        ]
        return titles.enumerated().map { index, title in
            RemoteSession(
                id: index == 1 ? conversationID : "reference-\(index)",
                title: title,
                projectID: index == 3 ? projects[1].id : project.id,
                projectName: index == 3 ? projects[1].name : project.name,
                updatedAt: Calendar.current.date(byAdding: .day, value: index < 7 ? -1 : -3, to: .now)!,
                status: .completed,
                isPinned: index == 1 || index == 2,
                canControl: true,
                additions: index == 3 ? 9 : 0
            )
        }
    }

    static let goal = TaskGoal(
        text: "为示例应用完成深色模式：检查背景、文字和按钮的对比度，保留现有布局。完成后列出改动和需要人工确认的事项。",
        isPaused: true, elapsed: "12分钟"
    )

    static let agents = [
        AgentTask(id: "ref-agent-1", title: "检查连接", status: .completed, detail: "演示任务：检查连接状态。", colorIndex: 0),
        AgentTask(id: "ref-agent-2", title: "审查样式", status: .completed, detail: "演示任务：整理样式建议。", colorIndex: 1),
        AgentTask(id: "ref-agent-3", title: "整理改动", status: .completed, detail: "演示任务：汇总文件变更。", colorIndex: 2),
        AgentTask(id: "ref-agent-4", title: "更新说明", status: .completed, detail: "演示任务：准备使用说明。", colorIndex: 3)
    ]

    static let longUserText = """
    请检查示例应用的登录页面。深色模式下，背景使用系统颜色，文字保持清晰；按钮保留原有位置，并确认较大字号时内容不会重叠。完成后给我一份简短的检查清单。这里的项目、聊天和文件均为虚构演示，不对应任何真实工作区。
    """

    static var messages: [ChatMessage] {
        [
            ChatMessage(id: "ref-assistant-1", role: .assistant,
                text: "已整理示例项目结构。下面先检查登录页的背景、文字与按钮。",
                elapsed: "1分钟",
                changes: [FileChange(path: "Sources/LoginView.swift", additions: 12, deletions: 4,
                    diff: "@@ -1,2 +1,3 @@\n import SwiftUI\n+// Demo: use semantic system colors.\n")]),
            ChatMessage(id: "ref-user-1", role: .user, text: "给登录页加入深色模式，保持现有布局。"),
            ChatMessage(id: "ref-assistant-2", role: .assistant,
                text: "这是演示结果：背景已改用系统颜色，文字与按钮层级保持清晰。\n\n| 检查项 | 演示状态 |\n| --- | --- |\n| 背景 | 已调整 |\n| 文字 | 已调整 |\n| 布局 | 保持原样 |",
                elapsed: "1分钟",
                steps: [ToolStep(id: "ref-step-1", title: "检查示例页面", detail: "读取演示视图"),
                        ToolStep(id: "ref-step-2", title: "整理样式建议", detail: "列出颜色和排版建议")]),
            ChatMessage(id: "ref-user-2", role: .user, text: longUserText),
            ChatMessage(id: "ref-assistant-3", role: .assistant,
                text: "示例改动已整理。真实项目还需要在目标设备上确认深色模式与较大字号下的显示效果。")
        ].map { message in
            var value = message
            let turnID: String
            switch message.id {
            case "ref-user-1", "ref-assistant-2": turnID = "reference-turn-1"
            case "ref-user-2", "ref-assistant-3": turnID = "reference-turn-2"
            default: turnID = "reference-turn-" + message.id
            }
            value.transcript = .init(turnID: turnID, state: .completed,
                                     role: message.role == .user ? .input : .finalAnswer)
            return value
        }
    }

    static let files: [RemoteFile] = [
        "DemoApp", "Sources", "Resources", "Tests", "Documentation"
    ].map {
        RemoteFile(name: $0, path: $0, isDirectory: true, children: [
            RemoteFile(name: "README.md", path: "\($0)/README.md", isDirectory: false, content: "# \($0)\n\n虚构演示项目。"),
            RemoteFile(name: "Example.swift", path: "\($0)/Example.swift", isDirectory: false, content: "import Foundation\n// Demonstration only.\n")
        ])
    } + [
        RemoteFile(name: "AGENTS.md", path: "AGENTS.md", isDirectory: false, content: "# 示例项目说明\n\n这是展示用的文本，不是助手执行指令。"),
        RemoteFile(name: "PROJECT_NOTES.md", path: "PROJECT_NOTES.md", isDirectory: false, content: "# 示例项目笔记\n\n不包含真实工作区信息。")
    ]
}

extension ReferenceData {
    static var homePreviewMessages: [ChatMessage] {
        [
            ChatMessage(id: "preview-previous", role: .assistant, text: "这里是演示对话。"),
            ChatMessage(id: "preview-user", role: .user, text: "继续调整按钮。"),
            ChatMessage(id: "preview-answer", role: .assistant,
                        text: "**演示改动已整理。**\n\n按钮圆角已调整，布局保持原样。真实任务状态以连接电脑返回的信息为准。",
                        elapsed: "1分钟")
        ].map { message in
            var value = message
            value.transcript = .init(turnID: "reference-preview-turn", state: .completed,
                                     role: message.role == .user ? .input : .finalAnswer)
            return value
        }
    }
}
