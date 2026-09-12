import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AppStore {
    var path: [AppRoute] = []
    var sheet: AppSheet?
    var connection: ConnectionState = .disconnected
    var hostName = "你的电脑"
    var isReferenceMode = false
    var referenceReview = false
    var sessions: [RemoteSession] = []
    var sessionListTruncated = false
    var projects: [RemoteProject] = []
    var transcripts: [String: [ChatMessage]] = [:]
    var histories: [String: ConversationHistory] = [:]
    var loadingHistory: Set<String> = []
    var pendingInteractions: [String: [PendingInteraction]] = [:]
    var options = SessionOptions()
    var sortOrder: SortOrder = .priority
    var showArchived = false
    var errorMessage: String?
    var toast: String?
    var isLoading = false
    var sendingSessions: Set<String> = []
    var drafts: [String: String] = [:]
    var localFeedback: [String: Int] = [:]
    var localUnreadIDs: Set<String> = []
    var locallyReadTimestamps: [String: Double] = [:]
    var goals: [String: TaskGoal] = [:]
    var agentTasks: [String: [AgentTask]] = [:]
    var hostGoals: [String: RelayHostGoal] = [:]
    var hostAgents: [String: RelayHostAgents] = [:]
    var changingGoals: Set<String> = []
    @ObservationIgnored private var changingHookReviews: Set<String> = []
    var hasConnectedBefore = false
    var requiresInitialConnection: Bool { !isReferenceMode && !hasConnectedBefore }
    var profiles: [ConnectionProfile] = []
    var activeProfileID: String?
    var selectedProjectID: String?
    var appearance = "跟随系统"
    var hapticsEnabled = true
    var showTimestamps = true
    var bridgeVersion: String?
    var streamConnected = false
    var models: [RemoteModel] = []
    var modelSelections: [String: ModelSelection] = [:]
    var remoteSettings: [String: RemoteSettings] = [:]
    var newModelSelection: ModelSelection?
    var projectSettings: [String: RemoteProjectSettings] = [:]
    var stoppingSessions: Set<String> = []
    var pendingSubmissions: [String: PendingSubmission] = [:]
    var draftAttachments: [String: [Attachment]] = [:]
    @ObservationIgnored private let draftAttachmentJournal = DraftAttachmentJournal()
    @ObservationIgnored private var loadedAttachmentDrafts: Set<String> = []
    @ObservationIgnored private var attachmentWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let submissionJournal = SubmissionJournal()
    @ObservationIgnored private var rejectedSubmissionIDs: Set<String> = []
    @ObservationIgnored private var transcriptRequests: [String: UUID] = [:]
    @ObservationIgnored private var eventRevision = 0
    @ObservationIgnored private var messageRevisions: [String: Int] = [:]
    @ObservationIgnored private var interactionRevisions: [String: Int] = [:]
    @ObservationIgnored private var sessionRevisions: [String: Int] = [:]
    @ObservationIgnored private var activityRevisions: [String: Int] = [:]
    @ObservationIgnored private var hostActivityVersions: [String: (epoch: String, sequence: Int, revision: Int)] = [:]
    @ObservationIgnored private var retiredActivityEpochs: [String: Set<String>] = [:]
    @ObservationIgnored private var indexRequest = UUID()
    @ObservationIgnored private var refreshRequest = UUID()

    var relayWorkspaces: [RelayWorkspace] = []
    @ObservationIgnored private var relayClient: RelayClient?
    @ObservationIgnored private var relayBootstrap: RelayBootstrap?
    @ObservationIgnored private var relayPairingText: String?
    @ObservationIgnored private var client: (any RemoteTransport)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var dirtySessionIDs: Set<String> = []
    @ObservationIgnored private var needsIndexRefresh = false
    @ObservationIgnored private var eventCursor: String?
    @ObservationIgnored private var connectionEpoch = UUID()
    @ObservationIgnored private var relayConnectionAttempt = UUID()
    @ObservationIgnored private var uploadedAttachments: [String: String] = [:]
    @ObservationIgnored private var localTitles: [String: String] = [:]
    @ObservationIgnored private var pinnedIDs: Set<String> = []
    @ObservationIgnored private var archivedIDs: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = decode([ConnectionProfile].self, key: "connections") ?? []
        hasConnectedBefore = defaults.object(forKey: "hasConnectedBefore") == nil
            ? !profiles.isEmpty : defaults.bool(forKey: "hasConnectedBefore")
        defaults.set(hasConnectedBefore, forKey: "hasConnectedBefore")
        activeProfileID = defaults.string(forKey: "activeConnection")
        drafts = decode([String: String].self, key: scopedKey("drafts")) ?? [:]
        localTitles = decode([String: String].self, key: scopedKey("titles")) ?? [:]
        pinnedIDs = Set(defaults.stringArray(forKey: scopedKey("pins")) ?? [])
        archivedIDs = Set(defaults.stringArray(forKey: scopedKey("archives")) ?? [])
        appearance = defaults.string(forKey: "appearance") ?? "跟随系统"
        hapticsEnabled = defaults.object(forKey: "haptics") as? Bool ?? true
        showTimestamps = defaults.object(forKey: "timestamps") as? Bool ?? true

        do { try loadScopedState() }
        catch { errorMessage = "无法恢复待发送消息：\(error.localizedDescription)" }

        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--reference") {
            referenceReview = args.contains("--visual-review")
            enterReferenceMode()
            if let index = args.firstIndex(of: "--screen"), args.count > index + 1 {
                switch args[index + 1] {
                case "chat", "goal", "agents", "keyboard", "reasoning", "permissions", "attachments", "thread-menu", "rename":
                    path = [.session(ReferenceData.conversationID)]
                case "new", "voice": path = [.newSession]
                case "hooks", "hooks-expired":
                    path = [.session(ReferenceData.conversationID)]
                    do { pendingInteractions[ReferenceData.conversationID] = [try ReferenceData.hookReviewInteraction(expired: args[index + 1] == "hooks-expired")] }
                    catch { errorMessage = "无法读取审查体验数据：\(error.localizedDescription)" }
                case "files": path = [.session(ReferenceData.conversationID)]; sheet = .files(ReferenceData.conversationID, false)
                case "advanced": path = [.session(ReferenceData.conversationID)]; sheet = .advanced
                case "offline": connection = .disconnected; sessions = []
                default: break
                }
            }
        }
        #endif
    }

    var activeProfile: ConnectionProfile? { profiles.first { $0.id == activeProfileID } }
    private var persistenceScope: String {
        isReferenceMode ? "reference" : "\(activeProfileID ?? "unconnected")|\(activeProfile?.baseURL ?? "")"
    }
    private func scopedKey(_ key: String) -> String { "\(persistenceScope)|\(key)" }
    private func loadScopedState() throws {
        localUnreadIDs = Set(defaults.stringArray(forKey: scopedKey("unread")) ?? [])
        locallyReadTimestamps = decode([String: Double].self, key: scopedKey("readTimestamps")) ?? [:]
        localFeedback = decode([String: Int].self, key: scopedKey("feedback")) ?? [:]
        drafts = decode([String: String].self, key: scopedKey("drafts")) ?? [:]
        // Goals and agents are host projections, never restored from local UI preferences.
        goals = [:]
        agentTasks = [:]
        hostGoals = [:]
        hostAgents = [:]
        localTitles = decode([String: String].self, key: scopedKey("titles")) ?? [:]
        pinnedIDs = Set(defaults.stringArray(forKey: scopedKey("pins")) ?? [])
        archivedIDs = Set(defaults.stringArray(forKey: scopedKey("archives")) ?? [])
        draftAttachments = [:]
        loadedAttachmentDrafts = []
        pendingSubmissions = [:]
        pendingSubmissions = try submissionJournal.read(scope: persistenceScope)
    }
    var currentSessionID: String? {
        if case let .session(id) = path.last { return id }
        return nil
    }
    var canManageGoals: Bool { isReferenceMode }

    func start() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bridge-acceptance"),
           let token = ProcessInfo.processInfo.environment["ZCODE_ACCEPTANCE_TOKEN"] {
            let baseURL = ProcessInfo.processInfo.environment["ZCODE_ACCEPTANCE_BASE_URL"] ?? "http://127.0.0.1:18789"
            let name = ProcessInfo.processInfo.environment["ZCODE_ACCEPTANCE_HOST_NAME"] ?? "Example-Mac.local"
            guard let endpoint = URL(string: baseURL), endpoint.scheme == "http", endpoint.host == "127.0.0.1",
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
                  endpoint.path.isEmpty || endpoint.path == "/", let port = endpoint.port else {
                errorMessage = "验收入口仅支持本机专用测试端口。"
                return
            }
            let profileID = port == 18789 ? "simulator-acceptance" : "simulator-acceptance-\(port)"
            await connect(ConnectionProfile(id: profileID, name: name, baseURL: baseURL), token: token)
            if let project = projects.first(where: { $0.name == "Mobile Acceptance" }) { selectedProjectID = project.id }
            return
        }
        #endif
        guard !isReferenceMode, let profile = activeProfile else { return }
        guard !profile.isRelay else { return }
        await connect(profile)
    }

    func enterReferenceMode() {
        disconnect()
        isReferenceMode = true
        localUnreadIDs = []; locallyReadTimestamps = [:]
        hostName = "Example-Mac.local"
        connection = .connected
        projects = ReferenceData.projects
        selectedProjectID = projects.first?.id
        sessions = ReferenceData.sessions
        transcripts = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, ReferenceData.messages) })
        transcripts["reference-2"] = ReferenceData.homePreviewMessages
        goals[ReferenceData.conversationID] = ReferenceData.goal
        agentTasks[ReferenceData.conversationID] = ReferenceData.agents
        options.model = "6 Astra"
        options.reasoning = .medium
        options.permission = .full
    }

    func leaveReferenceMode() {
        disconnect()
        isReferenceMode = false
        referenceReview = false
        sessions = []
        transcripts = [:]
        histories = [:]; loadingHistory = []
        projects = []
        goals = [:]
        agentTasks = [:]
        hostName = activeProfile?.name ?? "你的电脑"
        options = SessionOptions()
        path = []
        Task { await start() }
    }

    /// Select an existing computer before awaiting its network response, so a failed
    /// switch can never leave the previous computer's tasks under the new heading.
    func switchComputer(_ profile: ConnectionProfile, confirmedControllerReplacement: Bool = false) async {
        guard profiles.contains(where: { $0 == profile }) else { return }
        if !isReferenceMode, activeProfile == profile, connection.isOnline {
            showArchived = false; path = []
            await refresh()
            return
        }
        guard !profile.isRelay || confirmedControllerReplacement else { return }
        disconnect()
        isReferenceMode = false; referenceReview = false
        activeProfileID = profile.id
        hostName = profile.name
        sessions = []; transcripts = [:]; projects = []; models = []
        pendingInteractions = [:]; modelSelections = [:]; remoteSettings = [:]
        projectSettings = [:]; uploadedAttachments = [:]; newModelSelection = nil
        options = SessionOptions(); selectedProjectID = nil
        path = []; sheet = nil; showArchived = false
        bridgeVersion = nil; errorMessage = nil; toast = nil; isLoading = false
        drafts = [:]; localFeedback = [:]; localUnreadIDs = []; locallyReadTimestamps = [:]
        draftAttachments = [:]; pendingSubmissions = [:]
        defaults.set(profile.id, forKey: "activeConnection")
        do { try loadScopedState() }
        catch { connection = .failed(error.localizedDescription); errorMessage = error.localizedDescription; return }
        await connect(profile, confirmedControllerReplacement: confirmedControllerReplacement)
    }

    func connect(_ profile: ConnectionProfile, token: String? = nil, confirmedControllerReplacement: Bool = false) async {
        if profile.isRelay {
            guard confirmedControllerReplacement else { return }
            guard let raw = token ?? CredentialStore.read(profile.id), let workspace = profile.relayWorkspaceKey else {
                errorMessage = "连接信息已失效，请重新扫描电脑上的二维码。"; return
            }
            let attempt = UUID()
            do {
                try await beginRelayPairing(raw, confirmedControllerReplacement: true, attempt: attempt)
                try await completeRelayPairing(workspaceKey: workspace, name: profile.name)
            } catch {
                guard relayConnectionAttempt == attempt else { return }
                disconnect()
                let message = Self.connectionErrorMessage(error)
                connection = .failed(message); errorMessage = message
            }
            return
        }
        guard let url = Self.validatedURL(profile.baseURL),
              let secret = token ?? CredentialStore.read(profile.id), !secret.isEmpty else {
            connection = .failed("请检查连接地址和密钥。")
            return
        }
        disconnect()
        let epoch = connectionEpoch
        connection = .connecting
        if let pin = profile.certificateSHA256,
           (url.scheme != "https" || pin.count != 64 || !pin.allSatisfy(\.isHexDigit)) {
            connection = .failed("连接证书信息无效，请重新扫描电脑上的二维码。")
            return
        }
        let newClient = BridgeClient(baseURL: url, token: secret, certificateSHA256: profile.certificateSHA256)
        do {
            let status: BridgeStatus = try await newClient.get("v1/status")
            guard epoch == connectionEpoch else { return }
            try CredentialStore.save(secret, id: profile.id)
            client = newClient
            sessions = []
            transcripts = [:]
            histories = [:]; loadingHistory = []
            pendingInteractions = [:]
            modelSelections = [:]
            remoteSettings = [:]
            uploadedAttachments = [:]
            options = SessionOptions()
            newModelSelection = nil
            projectSettings = [:]
            goals = [:]
            agentTasks = [:]
            if isReferenceMode || activeProfileID != profile.id { path = [] }
            isReferenceMode = false
            hostName = status.hostName
            bridgeVersion = status.zcodeVersion
            activeProfileID = profile.id
            if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile }
            else { profiles.append(profile) }
            try loadScopedState()
            save(profiles, key: "connections")
            defaults.set(profile.id, forKey: "activeConnection")
            connection = .connected
            try await loadRemoteIndex()
            guard epoch == connectionEpoch else { return }
            beginStreaming()
        } catch {
            guard epoch == connectionEpoch else { return }
            disconnect()
            let message = Self.connectionErrorMessage(error)
            connection = .failed(message)
            errorMessage = message
        }
    }

    private static func connectionErrorMessage(_ error: Error) -> String {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch URLError.Code(rawValue: failure.code) {
        case .cannotConnectToHost:
            return "无法连接到这台电脑。请确认电脑上的 ZCode 和远程连接服务正在运行。"
        case .cannotFindHost, .dnsLookupFailed:
            return "找不到这台电脑。请检查连接地址和网络。"
        case .notConnectedToInternet:
            return "当前没有网络连接。联网后可以重新连接电脑。"
        case .networkConnectionLost:
            return "与电脑的连接已中断，草稿已保留。请重新连接。"
        case .timedOut:
            return "连接电脑超时。请检查电脑和网络后重试。"
        default:
            return error.localizedDescription
        }
    }

    func refreshRelayWorkspaces() async throws {
        guard let relayClient, relayBootstrap != nil else {
            throw BridgeFailure(message: "连接已结束，请重新扫描电脑的连接码。", code: "relay_not_paired")
        }
        let epoch = connectionEpoch
        let bootstrap = try await relayClient.workspaces()
        guard epoch == connectionEpoch else { throw CancellationError() }
        relayBootstrap = bootstrap
        relayWorkspaces = bootstrap.workspaces
    }

    func beginRelayPairing(_ raw: String, confirmedControllerReplacement: Bool, attempt: UUID = UUID()) async throws {
        let pairing = try RelayPairing(scannedURL: raw)
        guard confirmedControllerReplacement else { throw BridgeFailure(message: "请先确认连接这台电脑。", code: "controller_confirmation_required") }
        disconnect()
        relayConnectionAttempt = attempt
        let epoch = connectionEpoch
        connection = .connecting
        let installationID = defaults.string(forKey: "relayInstallationID") ?? UUID().uuidString
        defaults.set(installationID, forKey: "relayInstallationID")
        let paired = try RelayClient(clientID: installationID)
        relayClient = paired
        do {
            try await paired.connect(pairing: pairing, confirmedControllerReplacement: true)
            let bootstrap = try await paired.bootstrap()
            guard epoch == connectionEpoch else { await paired.disconnect(); throw CancellationError() }
            relayBootstrap = bootstrap
            relayWorkspaces = bootstrap.workspaces
            relayPairingText = raw
            hostName = pairing.deviceName
        } catch {
            guard epoch == connectionEpoch else { throw CancellationError() }
            connection = .failed(error.localizedDescription)
            await paired.disconnect()
            throw error
        }
    }

    func completeRelayPairing(workspaceKey: String, name: String) async throws {
        guard let paired = relayClient, let bootstrap = relayBootstrap, let raw = relayPairingText,
              bootstrap.workspaces.contains(where: { $0.id == workspaceKey && $0.canAttach }) else {
            throw BridgeFailure(message: "这个项目当前无法连接，请在电脑上激活后重试。", code: "relay_workspace_unavailable")
        }
        let epoch = connectionEpoch
        if let old = client as? RelayRemoteTransport { await old.shutdown() }
        guard epoch == connectionEpoch else { throw CancellationError() }
        streamTask?.cancel(); refreshTask?.cancel()
        let bridge = try await paired.openWorkspace(key: workspaceKey)
        let pairing = try RelayPairing(scannedURL: raw)
        let adapter = try await RelayRemoteTransport(client: paired, bootstrap: bootstrap, bridge: bridge,
                                                     hostName: name.isEmpty ? pairing.deviceName : name)
        guard epoch == connectionEpoch else { await adapter.shutdown(); throw CancellationError() }
        let existing = profiles.first { $0.relayDeviceID == pairing.deviceID && $0.relayWorkspaceKey == workspaceKey }
        let profile = ConnectionProfile(id: existing?.id ?? UUID().uuidString,
            name: name.isEmpty ? pairing.deviceName : name, baseURL: "https://zcode.z.ai/remote/v4",
            relayDeviceID: pairing.deviceID, relayWorkspaceKey: workspaceKey)
        try CredentialStore.save(raw, id: profile.id)
        client = adapter
        sessions = []; transcripts = [:]; histories = [:]; loadingHistory = []; pendingInteractions = [:]
        modelSelections = [:]; remoteSettings = [:]; uploadedAttachments = [:]
        projectSettings = [:]; newModelSelection = nil; options = SessionOptions()
        path = []; isReferenceMode = false; referenceReview = false
        activeProfileID = profile.id
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        try loadScopedState()
        save(profiles, key: "connections")
        defaults.set(profile.id, forKey: "activeConnection")
        hostName = profile.name; bridgeVersion = pairing.appVersion
        connection = .connected
        try await loadRemoteIndex()
        guard epoch == connectionEpoch else { throw CancellationError() }
        beginStreaming()
    }

    func cancelRelayPairing(attempt: UUID) {
        if relayConnectionAttempt == attempt { disconnect() }
    }

    static func validatedURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        return url
    }

    func disconnect() {
        connectionEpoch = UUID()
        relayConnectionAttempt = UUID()
        streamTask?.cancel()
        refreshTask?.cancel()
        streamTask = nil
        refreshTask = nil
        dirtySessionIDs = []
        needsIndexRefresh = false
        if let adapter = client as? RelayRemoteTransport { Task { await adapter.shutdown() } }
        if let relayClient { Task { await relayClient.disconnect() } }
        relayClient = nil
        relayBootstrap = nil
        relayPairingText = nil
        relayWorkspaces = []
        client = nil
        eventCursor = nil
        streamConnected = false
        transcriptRequests = [:]
        histories = [:]; loadingHistory = []
        messageRevisions = [:]
        interactionRevisions = [:]
        sessionRevisions = [:]
        activityRevisions = [:]
        hostActivityVersions = [:]; retiredActivityEpochs = [:]
        goals = [:]; hostGoals = [:]; hostAgents = [:]; agentTasks = [:]
        indexRequest = UUID()
        eventRevision = 0
        connection = .disconnected
        sessionListTruncated = false
        sendingSessions = []
        stoppingSessions = []
        changingGoals = []
        rejectedSubmissionIDs = []
    }

    func removeConnection(_ profile: ConnectionProfile) {
        if activeProfileID == profile.id {
            disconnect()
            activeProfileID = nil
            defaults.removeObject(forKey: "activeConnection")
            path = []; projects = []; selectedProjectID = nil
            sessions = []
            transcripts = [:]
            histories = [:]; loadingHistory = []
        }
        CredentialStore.remove(profile.id)
        profiles.removeAll { $0.id == profile.id }
        save(profiles, key: "connections")
    }

    func refresh() async {
        guard !isReferenceMode else { return }
        if client == nil, let activeProfile { await connect(activeProfile); return }
        let request = UUID()
        refreshRequest = request
        isLoading = true
        let epoch = connectionEpoch
        defer { if epoch == connectionEpoch, refreshRequest == request { isLoading = false } }
        do {
            try await loadRemoteIndex()
            guard epoch == connectionEpoch, refreshRequest == request else { return }
            connection = .connected
        } catch {
            guard epoch == connectionEpoch, refreshRequest == request else { return }
            connection = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func loadRemoteIndex() async throws {
        guard let client else { return }
        struct Projects: Decodable, Sendable { var projects: [RemoteProject] }
        struct Pagination: Decodable, Sendable {
            var snapshotId: String
            var total: Int?
            var hasMore: Bool
            var nextCursor: String?
            var truncated: Bool
        }
        struct Sessions: Decodable, Sendable { var sessions: [BridgeSession]; var pagination: Pagination? }
        struct Models: Decodable, Sendable { var models: [RemoteModel] }
        let epoch = connectionEpoch
        let request = UUID()
        indexRequest = request
        let revision = eventRevision
        async let p: Projects = client.get("v1/projects")
        async let s: Sessions = client.get("v1/sessions?includeArchived=true&limit=100")
        async let m: Models = client.get("v1/models")
        let (projectResponse, firstPage, modelResponse) = try await (p, s, m)
        var sessionResponse = firstPage
        var truncated = false
        var activeFirstPage = firstPage
        var restarted = false
        while true {
            var page = activeFirstPage
            sessionResponse = activeFirstPage
            var cursors: Set<String> = []
            truncated = activeFirstPage.pagination?.truncated ?? (activeFirstPage.sessions.count >= 100)
            do {
                while page.pagination?.hasMore == true {
                    guard epoch == connectionEpoch, indexRequest == request else { return }
                    guard let cursor = page.pagination?.nextCursor, cursors.insert(cursor).inserted,
                          sessionResponse.sessions.count < 5_000 else { truncated = true; break }
                    var query = URLComponents()
                    query.queryItems = [URLQueryItem(name: "includeArchived", value: "true"),
                                        URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "cursor", value: cursor)]
                    let next: Sessions = try await client.get("v1/sessions?\(query.percentEncodedQuery ?? "")")
                    guard next.pagination?.snapshotId == activeFirstPage.pagination?.snapshotId else {
                        throw BridgeFailure(message: "任务列表已更新，请刷新后重试。", code: "session_cursor_mismatch")
                    }
                    sessionResponse.sessions.append(contentsOf: next.sessions)
                    truncated = truncated || (next.pagination?.truncated ?? true)
                    page = next
                }
                break
            } catch {
                let code = (error as? BridgeFailure)?.code ?? (error as? RelayFailure)?.code
                guard !restarted, code == "session_cursor_expired" || code == "session_cursor_mismatch" else { throw error }
                guard epoch == connectionEpoch, indexRequest == request else { return }
                restarted = true
                activeFirstPage = try await client.get("v1/sessions?includeArchived=true&limit=100")
            }
        }
        guard epoch == connectionEpoch, indexRequest == request else { return }
        projects = projectResponse.projects
        sessionListTruncated = truncated
        let current = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let incomingIDs = Set(sessionResponse.sessions.map(\.id))
        var merged = sessionResponse.sessions.map { remote in
            if (sessionRevisions[remote.id] ?? 0) > revision, let live = current[remote.id] { return live }
            return decorate(remote.local)
        }
        merged.append(contentsOf: sessions.filter { !incomingIDs.contains($0.id) && (sessionRevisions[$0.id] ?? 0) > revision })
        sessions = merged
        models = modelResponse.models
        for session in sessionResponse.sessions {
            if let provider = session.providerId, let model = session.model {
                modelSelections[session.id] = ModelSelection(providerId: provider, modelId: model, thoughtLevel: session.thoughtLevel)
            }
        }
        if !projects.contains(where: { $0.id == selectedProjectID }) { selectedProjectID = projects.first?.id }
        if !hasConnectedBefore {
            hasConnectedBefore = true
            defaults.set(true, forKey: "hasConnectedBefore")
        }
    }

    func previewMessages(_ id: String) async throws -> [ChatMessage] {
        if isReferenceMode { return messages(id) }
        guard let client else { throw BridgeFailure(message: "连接已断开。", code: "offline") }
        let epoch = connectionEpoch
        let detail: BridgeDetail = try await client.get("v1/sessions/\(id)")
        guard epoch == connectionEpoch else { throw CancellationError() }
        return detail.messages.map(\.local)
    }

    func loadTranscript(_ id: String, onFailure: ((String) -> Void)? = nil) async {
        guard !isReferenceMode, let client else { return }
        let epoch = connectionEpoch
        let request = UUID()
        transcriptRequests[id] = request
        let revision = eventRevision
        do {
            let detail: BridgeDetail = try await client.get("v1/sessions/\(id)")
            guard epoch == connectionEpoch, transcriptRequests[id] == request else { return }
            let current = Dictionary((transcripts[id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            let incomingIDs = Set(detail.messages.map(\.id))
            var merged = detail.messages.map { item in
                if (messageRevisions["\(id)|\(item.id)"] ?? 0) > revision, let live = current[item.id] { return live }
                return item.local
            }
            merged.append(contentsOf: (transcripts[id] ?? []).filter {
                !incomingIDs.contains($0.id) && (messageRevisions["\(id)|\($0.id)"] ?? 0) > revision
            })
            transcripts[id] = merged
            histories[id] = detail.history
            if (interactionRevisions[id] ?? 0) <= revision { pendingInteractions[id] = detail.pendingInteractions }
            if (activityRevisions[id] ?? 0) <= revision { applyHostActivity(detail.hostActivity, sessionID: id) }
            if (sessionRevisions[id] ?? 0) <= revision {
                eventRevision += 1
                sessionRevisions[id] = eventRevision
                upsert(decorate(detail.session.local))
            }
            if let provider = detail.session.providerId, let model = detail.session.model {
                modelSelections[id] = ModelSelection(providerId: provider, modelId: model, thoughtLevel: detail.session.thoughtLevel)
            }
        } catch {
            guard epoch == connectionEpoch, transcriptRequests[id] == request else { return }
            if let onFailure { onFailure(error.localizedDescription) }
            else { errorMessage = error.localizedDescription }
        }
    }

    func loadEarlierMessages(_ id: String) async {
        guard !isReferenceMode, let client, !loadingHistory.contains(id),
              let history = histories[id], history.hasMore, let before = history.beforeRowId else { return }
        let epoch = connectionEpoch
        let request = UUID()
        transcriptRequests[id] = request
        let revision = eventRevision
        loadingHistory.insert(id)
        defer { if epoch == connectionEpoch { loadingHistory.remove(id) } }
        do {
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "beforeRowId", value: String(before)),
                                URLQueryItem(name: "logEpoch", value: history.logEpoch),
                                URLQueryItem(name: "limit", value: "200")]
            let page: BridgeHistoryPage = try await client.get("v1/sessions/\(id)/messages?\(query.percentEncodedQuery ?? "")")
            guard epoch == connectionEpoch, transcriptRequests[id] == request else { return }
            let current = Dictionary((transcripts[id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            let incomingIDs = Set(page.messages.map(\.id))
            var merged = page.messages.map { item in
                if (messageRevisions["\(id)|\(item.id)"] ?? 0) > revision, let live = current[item.id] { return live }
                return item.local
            }
            merged.append(contentsOf: (transcripts[id] ?? []).filter {
                !incomingIDs.contains($0.id) && (messageRevisions["\(id)|\($0.id)"] ?? 0) > revision
            })
            transcripts[id] = merged
            histories[id] = page.history
        } catch {
            guard epoch == connectionEpoch, transcriptRequests[id] == request else { return }
            if let failure = error as? BridgeFailure, failure.code == "relay_history_changed" {
                await loadTranscript(id)
                guard epoch == connectionEpoch else { return }
                errorMessage = "电脑上的会话刚刚更新，已刷新记录。请再次加载更早的消息。"
            } else { errorMessage = "无法加载更早的消息：\(error.localizedDescription)" }
        }
    }

    func createSession(text: String, persistedBody: [String: JSONValue]? = nil) async -> String? {
        guard let project = projects.first(where: { $0.id == selectedProjectID }) ?? projects.first else {
            errorMessage = "请先选择一个项目。"; return nil
        }
        let title = String(text.prefix(36))
        if isReferenceMode {
            let id = "reference-created-\(UUID().uuidString)"
            sessions.insert(RemoteSession(id: id, title: title, projectID: project.id, projectName: project.name,
                updatedAt: .now, canControl: true), at: 0)
            transcripts[id] = []
            return id
        }
        guard let client, connection.isOnline else { errorMessage = "请先连接你的电脑。"; return nil }
        let epoch = connectionEpoch
        struct Created: Decodable, Sendable { var session: BridgeSession }
        do {
            var body: [String: JSONValue] = ["projectId": .string(project.id), "title": .string(title.isEmpty ? "新任务" : title),
                                           "mode": .string(options.isPlanMode ? "plan" : options.permission.wireValue)]
            if !options.isPlanMode && options.permission == .full { body["confirmFullAccess"] = .bool(true) }
            if let newModelSelection { body["model"] = newModelSelection.json }
            if let persistedBody { body = persistedBody }
            let created: Created = try await client.mutate("v1/sessions", body: body)
            guard epoch == connectionEpoch else { return nil }
            upsert(created.session.local)
            if let provider = created.session.providerId, let model = created.session.model {
                modelSelections[created.session.id] = ModelSelection(providerId: provider, modelId: model, thoughtLevel: created.session.thoughtLevel)
            }
            return created.session.id
        } catch {
            guard epoch == connectionEpoch else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func messageLengthError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeProfile?.isRelay == true {
            return trimmed.utf8.count > 128_000 ? "消息太长，请缩短内容或改为附加文件后发送。" : nil
        }
        return trimmed.utf16.count > 32_000 ? "消息太长，请缩短内容或改为附加文件后发送。" : nil
    }

    /// A failed attempt remains immutable until it is acknowledged; changed drafts stay separate.
    func submitDraft(_ text: String, attachments: [Attachment], draftKey: String, sessionID: String?,
                     retryPending: Bool = false) async -> String? {
        if isReferenceMode {
            let targetID: String?
            if let sessionID { targetID = sessionID } else { targetID = await createSession(text: text) }
            guard let id = targetID else { return nil }
            return await send(text, to: id, attachments: attachments) ? id : nil
        }
        let epoch = connectionEpoch
        let scope = persistenceScope
        guard connection.isOnline, client != nil else { errorMessage = "请先连接电脑，草稿会保留。"; return nil }
        var entry: PendingSubmission
        if let pending = pendingSubmissions[draftKey] {
            guard retryPending || pending.matches(text: text, attachments: attachments) else {
                errorMessage = "上一条消息尚未确认送达。请先重试上一条；当前修改会保留为草稿。"
                return nil
            }
            entry = pending
        } else {
            if let error = messageLengthError(text) { errorMessage = error; return nil }
            var creation: [String: JSONValue]?
            if sessionID == nil {
                guard let projectID = selectedProjectID else { errorMessage = "请先选择项目。"; return nil }
                let title = String(text.prefix(36))
                var body: [String: JSONValue] = [
                    "projectId": .string(projectID), "clientDraftId": .string(UUID().uuidString),
                    "title": .string(title.isEmpty ? "新任务" : title),
                    "mode": .string(options.isPlanMode ? "plan" : options.permission.wireValue)
                ]
                if !options.isPlanMode && options.permission == .full { body["confirmFullAccess"] = .bool(true) }
                if let newModelSelection { body["model"] = newModelSelection.json }
                creation = body
            }
            entry = PendingSubmission(draftKey: draftKey, sessionID: sessionID, creation: creation,
                                      text: text, attachments: attachments)
            pendingSubmissions[draftKey] = entry
        }
        // Even a retry must have a durable journal before its first network mutation.
        do { try submissionJournal.write(pendingSubmissions, scope: scope) }
        catch { errorMessage = "无法保存待发送消息：\(error.localizedDescription)"; return nil }
        if entry.sessionID == nil {
            guard let id = await createSession(text: entry.text, persistedBody: entry.creation),
                  epoch == connectionEpoch else { return nil }
            entry.sessionID = id
            pendingSubmissions[draftKey] = entry
            do { try submissionJournal.write(pendingSubmissions, scope: scope) }
            catch { errorMessage = "任务已创建，待发送消息保存失败：\(error.localizedDescription)"; return nil }
        }
        guard let id = entry.sessionID else { return nil }
        for (attachmentID, remoteID) in entry.uploadedIDs { uploadedAttachments["\(id):\(attachmentID)"] = remoteID }
        let accepted = await send(entry.text, to: id, inputID: entry.id, attachments: entry.attachments)
        guard epoch == connectionEpoch else { return nil }
        for attachment in entry.attachments {
            if let remoteID = uploadedAttachments["\(id):\(attachment.id)"] { entry.uploadedIDs[attachment.id] = remoteID }
        }
        let rejected = rejectedSubmissionIDs.remove(entry.id) != nil
        pendingSubmissions[draftKey] = accepted || rejected ? nil : entry
        do { try submissionJournal.write(pendingSubmissions, scope: scope) }
        catch { errorMessage = "发送记录保存失败；下次重试会使用相同编号：\(error.localizedDescription)" }
        return accepted ? id : nil
    }

    var effectiveNewModelSelection: ModelSelection? {
        newModelSelection ?? selectedProjectID.flatMap { projectSettings[$0]?.model }
    }

    func loadProjectSettings(_ id: String) async {
        guard !isReferenceMode, let client else { return }
        let epoch = connectionEpoch
        do {
            let settings: RemoteProjectSettings = try await client.get("v1/projects/\(id)/settings")
            guard epoch == connectionEpoch else { return }
            projectSettings[id] = settings
        } catch {
            guard epoch == connectionEpoch else { return }
            errorMessage = error.localizedDescription
        }
    }

    func send(_ text: String, to id: String, inputID: String = UUID().uuidString, attachments: [Attachment] = []) async -> Bool {
        let epoch = connectionEpoch
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        if !isReferenceMode, let error = messageLengthError(text) {
            rejectedSubmissionIDs.insert(inputID)
            errorMessage = error
            return false
        }
        guard session(id)?.canControl == true else {
            errorMessage = "这个任务当前只能查看。你可以新建一个手机可控制的任务。"; return false
        }
        let isPendingRetry = pendingSubmissions.values.contains { $0.id == inputID && $0.sessionID == id && $0.matches(text: text, attachments: attachments) }
        guard !sendingSessions.contains(id), (![SessionStatus.running, .waiting].contains(session(id)?.status ?? .idle)) || isPendingRetry else { return false }
        sendingSessions.insert(id)
        defer { if epoch == connectionEpoch { sendingSessions.remove(id) } }
        if isReferenceMode {
            transcripts[id, default: []].append(ChatMessage(id: inputID, role: .user, text: trimmed))
            setStatus(id, .running)
            if drafts[id] == text { setDraft("", for: id) }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard session(id)?.status == .running else { return }
                transcripts[id, default: []].append(ChatMessage(id: UUID().uuidString, role: .assistant,
                    text: "已收到这条消息。\n\n你正在体验界面；连接电脑后，这里会显示 ZCode 的真实执行过程与回复。"))
                setStatus(id, .completed)
            }
            return true
        }
        guard let client else { errorMessage = "连接已断开，草稿已保留。"; return false }
        struct Accepted: Decodable, Sendable { var accepted: Bool }
        do {
            struct Upload: Decodable, Sendable {
                struct Value: Decodable, Sendable { var id: String }
                var attachment: Value
            }
            var attachmentIDs: [String] = []
            for attachment in attachments {
                let key = "\(id):\(attachment.id)"
                if let cached = uploadedAttachments[key] { attachmentIDs.append(cached) }
                else {
                    let result: Upload = try await client.mutate("v1/sessions/\(id)/attachments",
                        body: ["fileName": .string(attachment.name), "mimeType": .string(attachment.mimeType),
                               "base64": .string(attachment.data.base64EncodedString())])
                    guard epoch == connectionEpoch else { return false }
                    uploadedAttachments[key] = result.attachment.id
                    if let draftKey = pendingSubmissions.first(where: { $0.value.id == inputID })?.key {
                        pendingSubmissions[draftKey]?.uploadedIDs[attachment.id] = result.attachment.id
                        try submissionJournal.write(pendingSubmissions, scope: persistenceScope)
                    }
                    attachmentIDs.append(result.attachment.id)
                }
            }
            let result: Accepted = try await client.mutate("v1/sessions/\(id)/messages",
                body: ["text": .string(trimmed), "inputId": .string(inputID), "attachmentIds": .array(attachmentIDs.map(JSONValue.string))])
            guard epoch == connectionEpoch else { return false }
            if result.accepted {
                if drafts[id] == text { setDraft("", for: id) }
                setStatus(id, .running)
                await loadTranscript(id)
            }
            return result.accepted
        } catch {
            guard epoch == connectionEpoch else { return false }
            if let failure = error as? BridgeFailure, ["invalid_request", "input_rejected"].contains(failure.code) {
                rejectedSubmissionIDs.insert(inputID)
                errorMessage = "\(failure.localizedDescription) 请修改后重新发送，草稿已保留。"
            } else if let failure = error as? BridgeFailure, ["invalid_attachment", "attachment_too_large", "attachment_type_unsupported", "invalid_file_name", "attachment_type_mismatch", "attachment_not_found", "attachment_changed", "model_does_not_support_images", "model_does_not_support_pdf"].contains(failure.code) {
                rejectedSubmissionIDs.insert(inputID)
                for attachment in attachments { uploadedAttachments.removeValue(forKey: "\(id):\(attachment.id)") }
                errorMessage = "\(failure.localizedDescription) 请调整附件后重新发送，草稿已保留。"
            } else { errorMessage = error.localizedDescription }
            await loadTranscript(id)
            return false
        }
    }

    func stop(_ id: String) async {
        if isReferenceMode { setStatus(id, .idle); return }
        guard let client else { return }
        let epoch = connectionEpoch
        guard !stoppingSessions.contains(id) else { return }
        stoppingSessions.insert(id)
        defer { if epoch == connectionEpoch { stoppingSessions.remove(id) } }
        struct Stopped: Decodable, Sendable { var stopped: Bool }
        do {
            let response: Stopped = try await client.post("v1/sessions/\(id)/stop", body: [:])
            guard epoch == connectionEpoch else { return }
            await loadTranscript(id)
            if !response.stopped { errorMessage = "电脑还没有确认停止，当前执行状态已刷新。" }
        } catch { if epoch == connectionEpoch { errorMessage = error.localizedDescription } }
    }

    /// Called only by the dedicated review sheet after its operation-specific confirmation.
    var hookReviewGeneration: UUID { connectionEpoch }
    func performHookReview(_ review: RelayHookReviewRequest, action: WorkspaceHookReviewAction, expectedGeneration: UUID, onFailure: ((String) -> Void)? = nil) async -> Bool {
        func reportFailure(_ message: String) {
            if let onFailure { onFailure(message) } else { errorMessage = message }
        }
        guard expectedGeneration == connectionEpoch else { return false }
        guard !isReferenceMode, let target = session(review.sessionId),
              target.source == "official-relay" || (target.source == "bridge" && target.canReviewHooks == true),
              let client else {
            reportFailure("此连接尚不支持工作区命令审查，请回到电脑端处理。")
            return false
        }
        guard pendingInteractions[review.sessionId]?.first(where: { $0.id == review.interactionId })?.hookReview == review,
              Date.now.timeIntervalSince1970 * 1000 < Double(review.deadlineAt) else {
            reportFailure("审查内容已更新或过期，请查看电脑的最新请求。")
            return false
        }
        let epoch = connectionEpoch
        let key = scopedKey("hook:\(epoch):\(review.sessionId):\(review.interactionId)")
        guard changingHookReviews.insert(key).inserted else { return false }
        defer { changingHookReviews.remove(key) }
        struct Accepted: Decodable, Sendable { let accepted: Bool; let sessionId: String }
        func json<T: Encodable>(_ value: T) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }
        do {
            var body: [String: JSONValue] = ["clientCommandId": .string(UUID().uuidString), "request": try json(review)]
            let route: String
            switch action {
            case .trust(let ids):
                route = "respond"
                body["reviewItemIds"] = .array(ids.map(JSONValue.string))
                body["confirmation"] = try json(review.confirmation(for: .trustSelected(itemIDs: ids), userConfirmed: true))
            case .revoke(let ids):
                route = "revoke"
                body["reviewItemIds"] = .array(ids.map(JSONValue.string))
                body["confirmation"] = try json(review.confirmation(for: .revokeSelected(itemIDs: ids), userConfirmed: true))
            case .setEnabled(let id, let enabled):
                route = "toggle"
                body["reviewItemId"] = .string(id)
                body["enabled"] = .bool(enabled)
                body["confirmation"] = try json(review.confirmation(for: .setEnabled(itemID: id, enabled: enabled), userConfirmed: true))
            }
            let result: Accepted = try await client.mutate("v1/sessions/\(review.sessionId)/hooks/review/\(route)", body: body)
            guard epoch == connectionEpoch else { return false }
            guard result.accepted, result.sessionId == review.sessionId else {
                reportFailure("电脑尚未确认这项操作，请刷新审查状态。")
                return false
            }
            await loadTranscript(review.sessionId, onFailure: onFailure)
            return epoch == connectionEpoch
        } catch {
            if epoch == connectionEpoch { reportFailure(error.localizedDescription) }
            return false
        }
    }

    func respond(_ interaction: PendingInteraction, allow: Bool) async {
        guard let client else { return }
        let epoch = connectionEpoch
        struct Accepted: Decodable, Sendable { var accepted: Bool }
        do {
            let _: Accepted = try await client.post("v1/interactions/\(interaction.id)/respond",
                body: interaction.kind == "permission" ? ["decision": allow ? "allow" : "deny"] : ["action": allow ? "accept" : "decline"])
            guard epoch == connectionEpoch else { return }
            await loadTranscript(interaction.sessionId)
        } catch { if epoch == connectionEpoch { errorMessage = error.localizedDescription } }
    }

    func answer(_ interaction: PendingInteraction, content: JSONValue?, decline: Bool = false) async -> Bool {
        guard let client else { return false }
        let epoch = connectionEpoch
        struct Accepted: Decodable, Sendable { var accepted: Bool }
        do {
            var body: [String: JSONValue] = ["action": .string(decline ? "decline" : "accept")]
            if let content { body["content"] = content }
            let result: Accepted = try await client.mutate("v1/interactions/\(interaction.id)/respond", body: body)
            guard epoch == connectionEpoch else { return false }
            await loadTranscript(interaction.sessionId)
            return result.accepted
        } catch { if epoch == connectionEpoch { errorMessage = error.localizedDescription }; return false }
    }

    var fileListingGeneration: UUID { connectionEpoch }

    func fileListing(projectID: String, path: String = "") async throws -> RemoteFileListing {
        if isReferenceMode { return RemoteFileListing(files: ReferenceData.files) }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+#?"))) ?? ""
        let response: BridgeFileListing = try await readFileResource("v1/projects/\(projectID)/files?path=\(escaped)")
        return RemoteFileListing(files: response.files.map(\.local),
                                 truncated: response.truncated == true || response.searchComplete == false)
    }

    func searchFiles(projectID: String, query: String) async throws -> BridgeFileListing {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+#?"))) ?? ""
        return try await readFileResource("v1/projects/\(projectID)/files?search=\(escaped)")
    }

    func changeSummary(_ id: String) async throws -> BridgeChanges {
        if isReferenceMode { return BridgeChanges(files: ReferenceData.messages.flatMap(\.changes)) }
        return try await readFileResource("v1/sessions/\(id)/changes")
    }

    func fileContent(projectID: String, path: String) async throws -> String {
        struct File: Decodable, Sendable { var content: String }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+#?"))) ?? ""
        let response: File = try await readFileResource("v1/projects/\(projectID)/file?path=\(escaped)")
        return response.content
    }

    private func readFileResource<T: Decodable & Sendable>(_ path: String) async throws -> T {
        try Task.checkCancellation()
        guard let client else { throw BridgeFailure(message: "连接已断开。", code: "offline") }
        let epoch = connectionEpoch
        do {
            let response: T = try await client.get(path)
            guard epoch == connectionEpoch else { throw CancellationError() }
            try Task.checkCancellation()
            return response
        } catch {
            guard epoch == connectionEpoch, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }

    func loadSettings(_ id: String) async {
        guard !isReferenceMode, session(id)?.canControl == true, let client else { return }
        let epoch = connectionEpoch
        do {
            let response: RemoteSettings = try await client.get("v1/sessions/\(id)/settings")
            guard epoch == connectionEpoch else { return }
            remoteSettings[id] = response
            modelSelections[id] = response.model
        } catch { if epoch == connectionEpoch { errorMessage = error.localizedDescription } }
    }

    func permission(for id: String?) -> PermissionMode {
        guard !isReferenceMode, let id, let settings = remoteSettings[id] else { return options.permission }
        return PermissionMode(wireValue: settings.permissionMode ?? settings.mode) ?? .ask
    }

    func isPlanMode(for id: String?) -> Bool {
        guard !isReferenceMode, let id, let settings = remoteSettings[id] else { return options.isPlanMode }
        return settings.mode == "plan"
    }

    func updateSettings(_ id: String?, model: ModelSelection? = nil, reasoning: String? = nil, mode: String? = nil,
                        permissionMode: String? = nil,
                        confirmFullAccess: Bool = false) async -> Bool {
        if isReferenceMode { return true }
        if (mode == "yolo" || permissionMode == "yolo") && !confirmFullAccess {
            errorMessage = "请先确认完全访问权限。"
            return false
        }
        guard let id else {
            if let model { newModelSelection = model }
            if let reasoning {
                if newModelSelection == nil { newModelSelection = effectiveNewModelSelection }
                newModelSelection?.thoughtLevel = reasoning
            }
            if let mode {
                options.isPlanMode = mode == "plan"
                if let permission = PermissionMode(wireValue: mode) { options.permission = permission }
            }
            if let permissionMode, let permission = PermissionMode(wireValue: permissionMode) { options.permission = permission }
            return true
        }
        guard let client else { return false }
        let epoch = connectionEpoch
        do {
            var body: [String: JSONValue] = [:]
            if let model { body["model"] = model.json }
            if let reasoning { body["thoughtLevel"] = .string(reasoning) }
            if let mode { body["mode"] = .string(mode) }
            if let permissionMode { body["permissionMode"] = .string(permissionMode) }
            if confirmFullAccess { body["confirmFullAccess"] = .bool(true) }
            let response: RemoteSettings = try await client.mutate("v1/sessions/\(id)/settings", method: "PATCH", body: body)
            guard epoch == connectionEpoch else { return false }
            remoteSettings[id] = response
            modelSelections[id] = response.model
            return true
        } catch { if epoch == connectionEpoch { errorMessage = error.localizedDescription }; return false }
    }

    private func mutateMetadata(_ id: String, body: [String: JSONValue]) async -> Bool {
        guard let client else { return false }
        let epoch = connectionEpoch
        let revision = eventRevision
        struct Updated: Decodable, Sendable { var session: BridgeSession }
        do {
            let response: Updated = try await client.mutate("v1/sessions/\(id)", method: "PATCH", body: body)
            guard epoch == connectionEpoch else { return false }
            if (sessionRevisions[id] ?? 0) <= revision {
                eventRevision += 1
                sessionRevisions[id] = eventRevision
                upsert(decorate(response.session.local))
            }
            return true
        } catch { if epoch == connectionEpoch { errorMessage = error.localizedDescription }; return false }
    }

    func changes(_ id: String) async throws -> [FileChange] {
        if isReferenceMode { return ReferenceData.messages.flatMap(\.changes) }
        guard let client else { return [] }
        struct Changes: Decodable, Sendable { var files: [FileChange] }
        let response: Changes = try await client.get("v1/sessions/\(id)/changes")
        return response.files
    }

    func session(_ id: String) -> RemoteSession? { sessions.first { $0.id == id } }
    func messages(_ id: String) -> [ChatMessage] { transcripts[id] ?? [] }
    func agentCount(_ id: String) -> Int {
        if isReferenceMode { return (agentTasks[id]?.isEmpty == false) ? 30 : 0 }
        guard let host = hostAgents[id], host.isVisible else { return 0 }
        return max(Set(host.childSessionIDs).count, Set(host.running.map(\.childSessionID)).count + host.endedTotal)
    }
    func goalTitle(_ id: String) -> String {
        guard let host = hostGoals[id], !isReferenceMode else {
            return goals[id]?.isPaused == true ? "已暂停的目标" : "正在追求目标"
        }
        return ["active": "正在追求目标", "paused": "已暂停的目标", "verifying": "正在验证目标",
                "verified": "已完成的目标", "notSatisfied": "正在继续目标", "failed": "目标遇到问题"][host.status] ?? "目标"
    }
    func goalElapsed(_ id: String, at date: Date) -> String {
        guard let host = hostGoals[id], !isReferenceMode else { return goals[id]?.elapsed ?? "" }
        let seconds = host.elapsedSeconds(atUnixMilliseconds: date.timeIntervalSince1970 * 1000)
        return "\(seconds / 3600)小时\(seconds / 60 % 60)分钟\(seconds % 60)秒"
    }
    func canToggleGoal(_ id: String) -> Bool {
        if isReferenceMode { return true }
        guard let goal = hostGoals[id], !changingGoals.contains(id) else { return false }
        return goal.isActive ? goal.pauseAvailable : goal.resumeAvailable
    }
    func toggleGoal(_ id: String) async {
        if isReferenceMode { goals[id]?.isPaused.toggle(); return }
        guard let goal = hostGoals[id], canToggleGoal(id), let client else { return }
        let epoch = connectionEpoch
        changingGoals.insert(id)
        defer { if epoch == connectionEpoch { changingGoals.remove(id) } }
        do {
            struct Result: Decodable, Sendable { var accepted: Bool }
            let result: Result = try await client.mutate("v1/sessions/\(id)/goal/\(goal.isActive ? "pause" : "resume")", body: [:])
            guard epoch == connectionEpoch else { return }
            if result.accepted { await loadTranscript(id) }
        } catch { if epoch == connectionEpoch { errorMessage = error.localizedDescription } }
    }
    private func applyHostActivity(_ activity: JSONValue?, sessionID id: String) {
        guard !isReferenceMode else { return }
        guard let activity, let encoded = try? JSONEncoder().encode(activity),
              let projection = try? RelayJSON(data: encoded) else {
            hostGoals[id] = nil; hostAgents[id] = nil; goals[id] = nil; agentTasks[id] = nil
            return
        }
        if let epoch = projection["logEpoch"].string, let sequence = projection["seq"].integer {
            let revision = projection["revision"].integer ?? 0
            guard retiredActivityEpochs[id]?.contains(epoch) != true else { return }
            if let previous = hostActivityVersions[id] {
                if previous.epoch == epoch {
                    guard sequence > previous.sequence || sequence == previous.sequence && revision >= previous.revision else { return }
                } else { retiredActivityEpochs[id, default: []].insert(previous.epoch) }
            }
            hostActivityVersions[id] = (epoch, sequence, revision)
        }
        let goal = RelayHostGoal(projection: projection)
        hostGoals[id] = goal
        goals[id] = goal.map { TaskGoal(text: $0.objective, isPaused: !$0.isActive, elapsed: goalElapsed(id, at: .now)) }
        let agents = RelayHostAgents(projection: projection)
        hostAgents[id] = agents
        guard let agents, agents.isVisible else { agentTasks[id] = nil; return }
        let rows = projection["rows"]["window"].array ?? []
        let ids = Array(Set(agents.childSessionIDs + agents.running.map(\.childSessionID))).sorted()
        agentTasks[id] = ids.enumerated().map { index, childID in
            if let active = agents.running.first(where: { $0.childSessionID == childID }) {
                return AgentTask(id: childID, title: active.title.isEmpty ? active.subagentType : active.title,
                                 status: active.status == "running" ? .running : .waiting,
                                 detail: active.summary ?? "", colorIndex: index % 4)
            }
            let row = rows.last { $0["kind"].string == "subagent" && $0["childSessionId"].string == childID }
            let title = row?["title"].string ?? session(childID)?.title ?? "智能体任务"
            return AgentTask(id: childID, title: title, status: row?["status"].string.flatMap(SessionStatus.init(rawValue:)) ?? .idle,
                             detail: row?["summaryText"].string ?? "打开以查看主机上的任务记录。", colorIndex: index % 4)
        }
    }
    func loadDraftAttachments(for id: String) async {
        guard !isReferenceMode, !loadedAttachmentDrafts.contains(id) else { return }
        let scope = persistenceScope, epoch = connectionEpoch
        let key = "\(scope)|\(id)"
        await attachmentWrites[key]?.value
        do {
            var values = try await draftAttachmentJournal.read(scope: scope, draftKey: id)
            guard epoch == connectionEpoch, scope == persistenceScope, !loadedAttachmentDrafts.contains(id) else { return }
            if values.isEmpty, let pending = pendingSubmissions[id], drafts[id] == pending.text {
                values = pending.attachments
                try await draftAttachmentJournal.write(values, scope: scope, draftKey: id)
                guard epoch == connectionEpoch, scope == persistenceScope, !loadedAttachmentDrafts.contains(id) else { return }
            }
            draftAttachments[id] = values
            loadedAttachmentDrafts.insert(id)
        } catch {
            guard epoch == connectionEpoch else { return }
            errorMessage = "无法恢复附件草稿：\(error.localizedDescription)"
        }
    }

    func setDraftAttachments(_ values: [Attachment], for id: String) {
        draftAttachments[id] = values
        loadedAttachmentDrafts.insert(id)
        guard !isReferenceMode else { return }
        let scope = persistenceScope, epoch = connectionEpoch
        let key = "\(scope)|\(id)", previous = attachmentWrites["\(scope)|\(id)"]
        attachmentWrites[key] = Task {
            await previous?.value
            do { try await draftAttachmentJournal.write(values, scope: scope, draftKey: id) }
            catch {
                if epoch == connectionEpoch { errorMessage = "附件草稿保存失败：\(error.localizedDescription)" }
            }
        }
    }

    func isUnread(_ id: String) -> Bool {
        guard let session = session(id) else { return localUnreadIDs.contains(id) }
        if !isReferenceMode, session.canMarkUnread ?? (session.unreadScope == "bridge" || activeProfile?.isRelay == true) {
            return session.unread ?? false
        }
        return localUnreadIDs.contains(id) || (session.unread == true && locallyReadTimestamps[id] != (session.unreadAt ?? 0))
    }

    func setUnread(_ unread: Bool, sessionID: String) {
        guard let session = session(sessionID) else { return }
        if !isReferenceMode, session.canMarkUnread ?? (session.unreadScope == "bridge" || activeProfile?.isRelay == true) {
            guard unread || session.unread == true else { return }
            var body: [String: JSONValue] = ["unread": .bool(unread)]
            if !unread, let stamp = session.unreadAt { body["expectedUnreadAt"] = .number(stamp) }
            let epoch = connectionEpoch
            Task { guard epoch == connectionEpoch else { return }; _ = await mutateMetadata(sessionID, body: body) }
            return
        }
        if unread { localUnreadIDs.insert(sessionID) }
        else { localUnreadIDs.remove(sessionID); locallyReadTimestamps[sessionID] = session.unreadAt ?? 0 }
        if !isReferenceMode {
            defaults.set(Array(localUnreadIDs), forKey: scopedKey("unread"))
            save(locallyReadTimestamps, key: scopedKey("readTimestamps"))
        }
    }

    func toggleLocalFeedback(_ value: Int, messageID: String, sessionID: String) {
        let key = "\(sessionID)|\(messageID)"
        localFeedback[key] = localFeedback[key] == value ? 0 : value
        if !isReferenceMode { save(localFeedback, key: scopedKey("feedback")) }
        haptic()
    }

    func setDraft(_ text: String, for id: String) {
        drafts[id] = text
        if !isReferenceMode { save(drafts, key: scopedKey("drafts")) }
    }
    func rename(_ id: String, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if !isReferenceMode {
            guard ["bridge", "official-relay"].contains(sessions[i].source) else {
                errorMessage = "这是电脑会话的只读镜像。请通过 ZCode 官方远程连接修改主机任务。"
                return
            }
            guard sessions[i].canRename != false else { errorMessage = "当前主机不支持此操作。"; return }
            let epoch = connectionEpoch
            Task { guard epoch == connectionEpoch else { return }; _ = await mutateMetadata(id, body: ["title": .string(value)]) }
            return
        }
        sessions[i].title = value
        if !isReferenceMode { localTitles[id] = value; save(localTitles, key: scopedKey("titles")) }
    }
    func setPinned(_ pinned: Bool, sessionID: String) {
        guard session(sessionID)?.isPinned != pinned else { return }
        togglePin(sessionID)
    }

    func togglePin(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if !isReferenceMode {
            guard ["bridge", "official-relay"].contains(sessions[i].source) else {
                errorMessage = "这是电脑会话的只读镜像。请通过 ZCode 官方远程连接修改主机任务。"
                return
            }
            let pinned = !sessions[i].isPinned
            guard sessions[i].canPin != false else { errorMessage = "当前主机不支持此操作。"; return }
            let epoch = connectionEpoch
            Task { guard epoch == connectionEpoch else { return }; _ = await mutateMetadata(id, body: ["pinned": .bool(pinned)]) }
            return
        }
        sessions[i].isPinned.toggle()
        if sessions[i].isPinned { pinnedIDs.insert(id) } else { pinnedIDs.remove(id) }
        if !isReferenceMode { defaults.set(Array(pinnedIDs), forKey: scopedKey("pins")) }
        haptic()
    }
    func archive(_ id: String, archived: Bool = true) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if !isReferenceMode {
            guard ["bridge", "official-relay"].contains(sessions[i].source) else {
                errorMessage = "这是电脑会话的只读镜像。请通过 ZCode 官方远程连接修改主机任务。"
                return
            }
            guard sessions[i].canArchive != false else { errorMessage = "当前主机不支持此操作。"; return }
            let epoch = connectionEpoch
            Task {
                guard epoch == connectionEpoch else { return }
                if await mutateMetadata(id, body: ["archived": .bool(archived)]) {
                    if archived { path = [] }
                    notify(archived ? "已归档" : "已恢复任务")
                }
            }
            return
        }
        sessions[i].isArchived = archived
        if archived { archivedIDs.insert(id) } else { archivedIDs.remove(id) }
        if !isReferenceMode { defaults.set(Array(archivedIDs), forKey: scopedKey("archives")) }
        if archived { path = []; notify("已归档") } else { notify("已恢复任务") }
    }
    private var forkJournal: ForkJournal { ForkJournal(directory: submissionJournal.directory.appendingPathComponent("Forks")) }
    var forksInFlight: Set<String> = []
    func isForking(_ id: String) -> Bool { forksInFlight.contains("\(persistenceScope)|\(id)") }

    /// Capture scope before scheduling; persist the command ID before any host mutation.
    func forkSession(_ id: String, target: MessageForkTarget? = nil) {
        guard let parent = session(id), !parent.isArchived else { return }
        if isReferenceMode {
            var child = parent
            child.id = UUID().uuidString; child.title += "（分支）"; child.updatedAt = .now
            child.isPinned = false; child.status = .idle
            upsert(child)
            let history = messages(id)
            if let target, let index = history.firstIndex(where: { $0.id == target.entityId }) {
                transcripts[child.id] = Array(history.prefix(index + 1))
            } else { transcripts[child.id] = history }
            path.append(.session(child.id))
            return
        }
        guard parent.canFork == true, connection.isOnline, let client else {
            errorMessage = "这台电脑当前不支持从此处创建分支。"
            return
        }
        let epoch = connectionEpoch, scope = persistenceScope
        let operationKey = "\(scope)|\(id)"
        guard !forksInFlight.contains(operationKey) else { return }
        let boundaryKey = "\(id)|\(target.map { "\($0.rowId)|\($0.entityId)" } ?? "latest")"
        let command: PendingFork
        do {
            var journal = try forkJournal.read(scope: scope)
            command = journal[boundaryKey] ?? PendingFork(clientForkId: UUID().uuidString, target: target)
            journal[boundaryKey] = command
            try forkJournal.write(journal, scope: scope)
        } catch {
            errorMessage = "无法保存分支请求：\(error.localizedDescription)"
            return
        }
        forksInFlight.insert(operationKey)
        Task {
            defer { forksInFlight.remove(operationKey) }
            guard epoch == connectionEpoch else { return }
            do {
                var body: [String: JSONValue] = ["clientForkId": .string(command.clientForkId)]
                if let target = command.target {
                    body["target"] = .object(["rowId": .number(Double(target.rowId)), "entityId": .string(target.entityId)])
                }
                struct Result: Decodable, Sendable { var session: BridgeSession; var forkedSessionId: String }
                let result: Result = try await client.mutate("v1/sessions/\(id)/fork", body: body)
                guard epoch == connectionEpoch else { return }
                guard result.session.id == result.forkedSessionId, result.forkedSessionId != id else {
                    throw BridgeFailure(message: "电脑返回的分支尚未确认，请重试。", code: "fork_uncertain")
                }
                var saved = try forkJournal.read(scope: scope)
                saved[boundaryKey] = nil; try forkJournal.write(saved, scope: scope)
                upsert(result.session.local)
                path.append(.session(result.forkedSessionId))
                notify("已创建分支")
            } catch {
                guard epoch == connectionEpoch else { return }
                if let failure = error as? BridgeFailure,
                   ["fork_rejected", "fork_target_stale", "fork_unavailable"].contains(failure.code) {
                    do {
                        var saved = try forkJournal.read(scope: scope)
                        saved[boundaryKey] = nil
                        try forkJournal.write(saved, scope: scope)
                        errorMessage = "电脑未创建分支：\(failure.message) 刷新会话后可重新选择回复。"
                    } catch { errorMessage = "无法更新分支请求记录：\(error.localizedDescription)" }
                } else {
                    errorMessage = "分支尚未确认：\(error.localizedDescription) 重试会使用同一请求编号。"
                }
            }
        }
    }

    func copy(_ value: String, message: String = "已复制") {
        UIPasteboard.general.string = value
        notify(message)
    }
    func notify(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }
    func haptic() {
        if hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
    }
    func savePreferences() {
        defaults.set(appearance, forKey: "appearance")
        defaults.set(hapticsEnabled, forKey: "haptics")
        defaults.set(showTimestamps, forKey: "timestamps")
    }
    private func setStatus(_ id: String, _ status: SessionStatus) {
        eventRevision += 1
        sessionRevisions[id] = eventRevision
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].status = status
            sessions[i].updatedAt = .now
        }
    }
    private func upsert(_ session: RemoteSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session }
        else { sessions.insert(session, at: 0) }
    }
    private func decorate(_ session: RemoteSession) -> RemoteSession {
        // Metadata always reflects the host. Legacy local preferences remain stored
        // for recovery, but cannot masquerade as a successful remote mutation.
        session
    }
    private func beginStreaming() {
        guard let client else { return }
        streamTask?.cancel()
        let epoch = connectionEpoch
        streamTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, epoch == self.connectionEpoch else { return }
                do {
                    try await client.events(after: self.eventCursor) { [weak self] event in
                        await self?.handle(event, epoch: epoch)
                    }
                    guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                    self.streamConnected = false
                    if self.activeProfile?.isRelay == true {
                        self.connection = .failed("远程连接已结束，请在连接页面重新连接电脑。")
                        return
                    }
                } catch {
                    guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                    self.streamConnected = false
                    if self.activeProfile?.isRelay == true {
                        self.connection = .failed((error as? BridgeFailure)?.code == "controller_replaced" ? "另一台手机已接管连接。你可以在连接页面手动重新连接。" : "远程连接已断开，草稿已保留。请手动重新连接电脑。")
                        return
                    }
                }
                attempt = min(attempt + 1, 5)
                try? await Task.sleep(for: .seconds(min(pow(2.0, Double(attempt)), 20)))
            }
        }
    }
    private func handle(_ event: BridgeEnvelope, epoch: UUID) {
        guard epoch == connectionEpoch else { return }
        eventCursor = event.id ?? eventCursor
        eventRevision += 1
        streamConnected = true
        if event.type == "ready" {
            if event.data?.connectionStatus == "disconnected" { connection = .failed("电脑上的 ZCode 已断开。") }
            return
        }
        if let remote = event.data?.session {
            sessionRevisions[remote.id] = eventRevision
            upsert(decorate(remote.local))
        }
        if let id = event.sessionId, let message = event.data?.message {
            messageRevisions["\(id)|\(message.id)"] = eventRevision
            if let index = transcripts[id]?.firstIndex(where: { $0.id == message.id }) {
                transcripts[id]?[index] = message.local
            } else { transcripts[id, default: []].append(message.local) }
            return
        }
        if let id = event.sessionId {
            if let activity = event.data?.hostActivity {
                activityRevisions[id] = eventRevision
                applyHostActivity(activity, sessionID: id)
            }
            if let interaction = event.data?.interaction {
                interactionRevisions[id] = eventRevision
                pendingInteractions[id, default: []].removeAll { $0.id == interaction.id }
                pendingInteractions[id, default: []].append(interaction)
            }
            if let interactionID = event.data?.interactionId {
                interactionRevisions[id] = eventRevision
                pendingInteractions[id]?.removeAll { $0.id == interactionID }
            }
            if event.type != "runtime.event" { dirtySessionIDs.insert(id) }
        }
        if ["session.created", "resync.required", "connection.changed"].contains(event.type) {
            needsIndexRefresh = true
            if let id = currentSessionID { dirtySessionIDs.insert(id) }
        }
        if event.type == "connection.changed", event.data?.connectionStatus == "disconnected" {
            connection = .failed("电脑上的 ZCode 已断开，正在等待恢复。")
        }
        guard !dirtySessionIDs.isEmpty || needsIndexRefresh, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == self.connectionEpoch { self.refreshTask = nil } }
            while !Task.isCancelled, epoch == self.connectionEpoch {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                let ids = self.dirtySessionIDs
                let refreshIndex = self.needsIndexRefresh
                self.dirtySessionIDs = []
                self.needsIndexRefresh = false
                if refreshIndex { await self.refresh() }
                for id in ids {
                    guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                    await self.loadTranscript(id)
                }
                if self.dirtySessionIDs.isEmpty && !self.needsIndexRefresh { return }
            }
        }
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
