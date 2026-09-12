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
}

struct FileChange: Identifiable, Codable, Hashable {
    var id: String { path }
    var path: String
    var additions: Int
    var deletions: Int
    var diff: String
    var truncated: Bool? = nil
}

struct RemoteFile: Identifiable, Codable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var children: [RemoteFile]? = nil
    var content: String? = nil
}

struct AgentTask: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: SessionStatus
    var detail: String
    var colorIndex: Int
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
    var permission: PermissionMode = .ask
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
    var isRelay: Bool { relayDeviceID != nil }
}

enum AppRoute: Hashable {
    case session(String)
    case newSession
}

enum AppSheet: Identifiable {
    case connections, settings, pairing, advanced, files(String, Bool), agent(AgentTask), voice
    var id: String {
        switch self {
        case .connections: "connections"
        case .settings: "settings"
        case .pairing: "pairing"
        case .advanced: "advanced"
        case let .files(id, modified): "files-\(id)-\(modified)"
        case let .agent(agent): "agent-\(agent.id)"
        case .voice: "voice"
        }
    }
}

struct Attachment: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var data: Data
    var mimeType: String
}
