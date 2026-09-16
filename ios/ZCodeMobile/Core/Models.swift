import Foundation

enum ConnectionState: Equatable {
    case disconnected, connecting, connected, failed(String)

    var isOnline: Bool { self == .connected }
    var label: String {
        switch self {
        case .disconnected: "离线"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .failed: "连接中断"
        }
    }
}

/// An in-memory handle for one explicitly confirmed computer pairing.
/// It carries no connection link or credential and cannot survive reconnecting.
struct RelayWorkspaceSelectionContext: Identifiable, Equatable, Sendable {
    let attempt: UUID
    let epoch: UUID
    let name: String
    let reason: String
    var id: UUID { epoch }
}

struct RemoteProject: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var path: String
}

enum SessionStatus: String, Codable, CaseIterable {
    case idle, running, waiting, completed, failed

    var label: String {
        switch self {
        case .idle: "就绪"
        case .running: "进行中"
        case .waiting: "等待批准"
        case .completed: "完成"
        case .failed: "需要关注"
        }
    }
}

struct RemoteSession: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var projectID: String
    var projectName: String
    var updatedAt: Date
    var status: SessionStatus = .idle
    var isPinned = false
    var isArchived = false
    var canControl = false
    var additions: Int = 0
    var deletions: Int = 0
    var source = "desktop"
    var unread: Bool?
    var unreadAt: Double?
    var unreadScope: String?
    var canMarkUnread: Bool?
    var canFork: Bool?
    var canReviewHooks: Bool?
    var canRename: Bool?
    var canPin: Bool?
    var canArchive: Bool?
}

enum SessionMenuActionID: String, Sendable {
    case pin, rename, unread, copyID, archive
}

struct SessionMenuItem: Identifiable, Equatable, Sendable {
    var id: SessionMenuActionID
    var title: String
    var symbol: String
    var destructive = false
    var isEnabled = true
}

enum SessionMenuPolicy {
    static func items(for session: RemoteSession, isReferenceMode: Bool, isRelay: Bool,
                      isOnline: Bool, isUnread: Bool) -> [SessionMenuItem] {
        // Older owned-session payloads omit these optional flags. Their metadata
        // support is independent of send, including archived tasks that can be restored.
        let owned = ["bridge", "official-relay"].contains(session.source)
        let remoteEnabled = isReferenceMode || isOnline
        var items: [SessionMenuItem] = []
        if isReferenceMode || (owned && session.canPin != false) {
            items.append(.init(id: .pin, title: session.isPinned ? "取消置顶" : "置顶",
                               symbol: session.isPinned ? "pin.slash" : "pin", isEnabled: remoteEnabled))
        }
        if isReferenceMode || (owned && session.canRename != false) {
            items.append(.init(id: .rename, title: "重命名", symbol: "pencil", isEnabled: remoteEnabled))
        }
        let syncsUnread = !isReferenceMode && (session.canMarkUnread ?? (session.unreadScope == "bridge" || isRelay))
        let localSuffix = !isReferenceMode && !syncsUnread ? "（仅此手机）" : ""
        items.append(.init(id: .unread, title: (isUnread ? "标记为已读" : "标记为未读") + localSuffix,
                           symbol: "circle.fill", isEnabled: !syncsUnread || isOnline))
        items.append(.init(id: .copyID, title: "复制对话串 ID", symbol: "square.on.square"))
        if isReferenceMode || (owned && session.canArchive != false) {
            items.append(.init(id: .archive, title: session.isArchived ? "取消归档" : "归档", symbol: "archivebox",
                               destructive: !session.isArchived, isEnabled: remoteEnabled))
        }
        return items
    }
}

struct MessageForkTarget: Codable, Hashable, Sendable {
    var rowId: Int
    var entityId: String
}

struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant, system, tool }
    var id: String
    var role: Role
    var text: String
    var createdAt: Date = .now
    var elapsed: String? = nil
    var steps: [ToolStep] = []
    var changes: [FileChange] = []
    var isStreaming = false
    var feedback: Int = 0
    var reasoning: String? = nil
    var attachments: [MessageAttachment] = []
    var forkTarget: MessageForkTarget?
    var transcript: TranscriptMessageSemantics? = nil
}

struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var fileName: String
    var mimeType: String
    var previewURL: String?
}

struct ToolStep: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var detail: String
    var status: SessionStatus = .completed
    var websiteURL: String? = nil
    var inputJSON: String? = nil
    var rawStatus: String? = nil

    var webAction: String? {
        let name = title.lowercased().replacingOccurrences(of: "_", with: "")
        if name.contains("webfetch") { return "获取" }
        if name.contains("websearch") { return "搜索" }
        return nil
    }
    var displayTitle: String {
        guard let action = webAction else { return title }
        switch status {
        case .running, .waiting: return action + "中"
        case .failed: return action + "失败"
        default: return "已" + action
        }
    }
    var website: URL? {
        guard let websiteURL, let url = URL(string: websiteURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    var faviconURL: URL? {
        guard let website, var parts = URLComponents(url: website, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        parts.path = "/favicon.ico"
        return parts.url
    }
}

struct FileChange: Identifiable, Codable, Hashable {
    var id: String { path }
    var path: String
    var additions: Int
    var deletions: Int
    var diff: String
    var truncated: Bool? = nil
}

struct RemoteFile: Identifiable, Codable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var children: [RemoteFile]? = nil
    var content: String? = nil
}

struct RemoteFileListing: Equatable, Sendable {
    var files: [RemoteFile]
    var truncated: Bool = false
}

struct AgentTask: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: SessionStatus
    var detail: String
    var colorIndex: Int
    var statusText: String? = nil
}

struct TaskGoal: Codable, Hashable {
    var text: String
    var isPaused: Bool
    var elapsed: String
}

enum SortOrder: String, CaseIterable, Identifiable {
    case priority = "优先级", project = "按项目", recent = "按时间倒序排列"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .priority: "bell"
        case .project: "folder"
        case .recent: "clock.arrow.circlepath"
        }
    }
}

enum ReasoningScale {
    static func angle(value: String, levels: [String]) -> Double {
        guard !levels.isEmpty, let index = levels.firstIndex(of: value) else { return -120 }
        // Each available level occupies an equal share; the highest fills the arc.
        return -120 + 240 * Double(index + 1) / Double(levels.count)
    }

    static func index(location: Double, width: Double, count: Int) -> Int? {
        guard count > 0, location.isFinite, width.isFinite else { return nil }
        let step = max(1, max(0, width - 73.333333) / Double(max(1, count - 1)))
        let position = min(Double(count - 1), max(0, (location - 36.666667) / step))
        return Int(position.rounded())
    }
}

enum ReasoningLevel: Int, CaseIterable, Codable, Identifiable {
    case minimal, low, medium, high, xhigh, maximum, ultra
    var id: Int { rawValue }
    var label: String { ["极低", "低", "中", "高", "极高", "最高", "超高"][rawValue] }
    var wireValue: String { ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"][rawValue] }
    init?(wireValue: String) {
        guard let value = Self.allCases.first(where: { $0.wireValue == wireValue }) else { return nil }
        self = value
    }
}

enum PermissionMode: String, CaseIterable, Codable, Identifiable {
    case ask, automatic, full, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "请求批准"
        case .automatic: "替我批准"
        case .full: "完全访问"
        case .custom: "自定义"
        }
    }
    var detail: String {
        switch self {
        case .ask: "编辑外部文件和使用互联网前始终先询问"
        case .automatic: "仅在检测到可能不安全的操作时进行询问"
        case .full: "完全访问计算机（风险较高）"
        case .custom: "使用电脑上定义的权限"
        }
    }
    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .automatic: "checkmark.shield"
        case .full: "exclamationmark.shield"
        case .custom: "gearshape"
        }
    }
    var wireValue: String {
        switch self {
        case .ask, .custom: "build"
        case .automatic: "edit"
        case .full: "yolo"
        }
    }
    init?(wireValue: String) {
        switch wireValue {
        case "build": self = .ask
        case "edit": self = .automatic
        case "yolo": self = .full
        default: return nil
        }
    }
}

struct SessionOptions: Codable, Hashable {
    var model = "GLM-5.3"
    var reasoning: ReasoningLevel = .high
    var permission: PermissionMode = .full
    var isPlanMode = false
    var speed = "标准"
}

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var baseURL: String
    var certificateSHA256: String?
    var relayDeviceID: String?
    var relayWorkspaceKey: String?
    var relayServiceID: String?
    var isRelay: Bool { relayDeviceID != nil }
}

enum AppRoute: Hashable {
    case session(String)
    case newSession
}

enum AppSheet: Identifiable {
    case connections, settings, pairing, advanced, files(String, Bool), agent(AgentTask), voice, mirror
    var id: String {
        switch self {
        case .connections: "connections"
        case .settings: "settings"
        case .pairing: "pairing"
        case .advanced: "advanced"
        case let .files(id, modified): "files-\(id)-\(modified)"
        case let .agent(agent): "agent-\(agent.id)"
        case .voice: "voice"
        case .mirror: "mirror"
        }
    }
}

struct Attachment: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var data: Data
    var mimeType: String
}

/// Product vocabulary shared by live tools, cached transcripts and reference review.
enum ToolActivityKind: String, CaseIterable {
    case command, read, write, search, files, webFetch, webSearch, build, test, versionControl
    case package, network, computer, agent, plan, question, wait, image, generic

    var symbol: String {
        switch self {
        case .command: "terminal"
        case .read: "doc.text.magnifyingglass"
        case .write: "square.and.pencil"
        case .search, .webSearch: "magnifyingglass"
        case .files: "folder"
        case .webFetch: "globe"
        case .build: "hammer"
        case .test: "checkmark.seal"
        case .versionControl: "arrow.triangle.branch"
        case .package: "shippingbox"
        case .network: "network"
        case .computer: "hand.tap"
        case .agent: "person.2"
        case .plan: "checklist"
        case .question: "bubble.left.and.bubble.right"
        case .wait: "clock"
        case .image: "photo"
        case .generic: "wrench.and.screwdriver"
        }
    }
    var verb: String {
        switch self {
        case .command: "运行"
        case .read: "读取"
        case .write: "修改"
        case .search, .webSearch: "搜索"
        case .files: "查看"
        case .webFetch: "获取"
        case .build: "构建"
        case .test: "测试"
        case .versionControl: "操作版本库"
        case .package: "管理依赖"
        case .network: "请求"
        case .computer: "操作"
        case .agent: "协作"
        case .plan: "规划"
        case .question: "询问"
        case .wait: "等待"
        case .image: "处理图片"
        case .generic: "调用"
        }
    }

    static func classify(_ title: String) -> Self {
        let full = title.lowercased()
        let leaf = full.components(separatedBy: "__").last ?? full
        let name = leaf.components(separatedBy: ".").last!.filter { $0.isLetter || $0.isNumber }
        if full.contains("cua") || full.contains("computer") || full.contains("browser") { return .computer }
        switch name {
        case "bash", "shell", "terminal", "exec", "execcommand", "runcommand", "writestdin": return .command
        case "read", "readfile", "readfiles": return .read
        case "write", "writefile", "edit", "editfile", "multiedit", "applypatch", "notebookedit": return .write
        case "grep", "glob", "rg", "search", "searchfiles", "findfiles": return .search
        case "ls", "list", "listfiles", "listdirectory", "directorytree": return .files
        case "webfetch", "fetchurl", "fetchwebpage": return .webFetch
        case "websearch", "searchweb": return .webSearch
        case "build", "buildproject", "xcodebuild": return .build
        case "test", "runtests", "testproject": return .test
        case "git", "gitstatus", "gitdiff", "gitlog", "gitcommit": return .versionControl
        case "installpackage", "installpackages", "packageinstall", "dependencies": return .package
        case "httprequest", "request", "apirequest": return .network
        case "agent", "task", "spawnagent", "sendmessagetoagent": return .agent
        case "todowrite", "todoread", "updateplan", "enterplanmode", "exitplanmode": return .plan
        case "askuserquestion", "requestuserinput", "requestuserinputasync": return .question
        case "wait", "sleep", "waitforcompletion": return .wait
        case "viewimage", "imagegen", "generateimage", "screenshot": return .image
        default: return .generic
        }
    }
}

extension ToolStep {
    var activityKind: ToolActivityKind { ToolActivityKind.classify(title) }
    var activityStatus: String {
        let verb = activityKind.verb
        if rawStatus.map({ ["cancelled", "canceled", "interrupted", "stopped"].contains($0.lowercased()) }) == true { return "已中断" }
        switch status {
        case .running: return activityKind == .webFetch || activityKind == .webSearch ? verb + "中" : "正在" + verb
        case .waiting: return rawStatus == "queued" ? "排队中" : "等待确认"
        case .failed: return verb + "失败"
        case .completed: return activityKind == .generic ? "已调用" : "已" + verb
        default: return "状态未确认"
        }
    }
    /// Never derive a summary from output: large results remain inside disclosure.
    var activitySummary: String {
        if activityKind == .webFetch, let host = website?.host { return host }
        let parsed: [String: Any]? = inputJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let string = parsed?[key] as? String, !string.isEmpty { return string }
                if let array = parsed?[key] as? [String], !array.isEmpty { return array.joined(separator: "、") }
            }
            return nil
        }
        let summary: String?
        switch activityKind {
        case .command: summary = value(["command", "cmd", "script", "description"])
        case .read, .write, .files:
            summary = value(["file_path", "filePath", "path", "paths", "file", "files", "description"]).map { path in
                path.components(separatedBy: "、").map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            }
        case .search, .webSearch: summary = value(["query", "pattern", "search_term", "description"])
        case .webFetch, .network: summary = value(["url", "uri", "description"]).flatMap { URL(string: $0)?.host }
        default: summary = value(["description", "title", "name", "query"])
        }
        let fallback = activityKind == .generic ? title : ""
        let text = summary ?? fallback
        return String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(180) ?? "")
    }
}

/// Tolerates terminal status arriving before the final message, without notifying for history loads.
struct AnswerCompletionFeedback {
    private var armed = false
    private var baseline: Set<String> = []
    private var delivered: Set<String> = []
    private func key(_ message: ChatMessage) -> String {
        message.transcript.map { "turn:" + $0.turnID } ?? "message:" + message.id
    }
    mutating func begin(_ messages: [ChatMessage]) {
        guard !armed else { return }
        armed = true
        baseline = Set(messages.filter { $0.role == .assistant && !$0.isStreaming && $0.transcript?.state != .running }.map(key))
    }
    mutating func observe(_ messages: [ChatMessage], status: SessionStatus) -> [String] {
        let replies = messages.filter { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !armed, status == .running || status == .waiting || replies.last?.isStreaming == true {
            armed = true
            baseline = Set(replies.filter { !$0.isStreaming && $0.transcript?.state != .running }.map(key))
        }
        guard armed else { return [] }
        var complete = replies.filter {
            !$0.isStreaming && $0.transcript?.state == .completed && $0.transcript?.role == .finalAnswer
        }
        if status == .completed, let last = replies.last, !last.isStreaming,
           last.transcript == nil || last.transcript?.role == .unknown || last.transcript?.role == .finalAnswer {
            complete.append(last)
        }
        let fresh = Set(complete.map(key)).subtracting(baseline).subtracting(delivered)
        delivered.formUnion(fresh)
        // Keep waiting if the completion event precedes the final text.
        if status == .completed && !fresh.isEmpty || status == .failed { armed = false }
        return fresh.sorted()
    }
}
