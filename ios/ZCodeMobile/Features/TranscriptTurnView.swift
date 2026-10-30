import SwiftUI

/// One reply owns its progress disclosure and one final-answer action bar.
/// Message identity remains unchanged when the user expands saved work.
struct TranscriptTurnView: View {
    let turn: TranscriptTurn
    let sessionID: String
    var allowsAutoCollapse = true
    @State var disclosure: TranscriptDisclosureState
    private var processExpanded: Bool { disclosure.expanded(turnID: turn.id, defaultValue: !turn.defaultCollapsed) }

    init(turn: TranscriptTurn, sessionID: String, allowsAutoCollapse: Bool = true,
         disclosure: TranscriptDisclosureState = TranscriptDisclosureState()) {
        self.turn = turn
        self.sessionID = sessionID
        self.allowsAutoCollapse = allowsAutoCollapse
        _disclosure = State(initialValue: disclosure)
    }
    @State private var fadingProcess = false
    @State private var inspectingTool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(turn.userMessages) { message in
                MessageView(message: message, sessionID: sessionID, showsResponseActions: false)
                    .padding(.top, 12).padding(.bottom, 34).id(message.id)
            }
            if !turn.processMessages.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if turn.canCollapseProcess {
                        Button {
                            // One height transaction; do not animate an entire long
                            // process subtree and its hosting cell at the same time.
                            disclosure.toggle(turnID: turn.id, defaultValue: !turn.defaultCollapsed)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "list.bullet").font(.system(size: 17, weight: .regular)).frame(width: 22).accessibilityHidden(true)
                                Text(processTitle)
                                Spacer(minLength: 8)
                                Image(systemName: processExpanded ? "chevron.down" : "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 16)
                            }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 28)
                        }.buttonStyle(.plain)
                            .accessibilityValue(processExpanded ? L10n.tr("已展开") : L10n.tr("已折叠"))
                            .accessibilityIdentifier("turn.process.\(turn.id)")
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                    if processExpanded {
                        processContent
                            .opacity(fadingProcess ? 0 : 1)
                            .transition(.identity)
                    }
                }
                .onPreferenceChange(ToolInspectionPreferenceKey.self) { inspectingTool = $0 }
                .padding(.bottom, 22)
            }
            ForEach(turn.resultMessages) { message in
                MessageView(message: message, sessionID: sessionID,
                            showsResponseActions: turn.actionMessageID == message.id)
                    .padding(.bottom, 22).id(message.id)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Re-evaluate allowsAutoCollapse after the delay: if the user scrolled
        // away (follow off), cancel collapse so height jumps do not yank history.
        // Task id includes allowsAutoCollapse so a mid-delay follow-off cancels.
        .task(id: "\(turn.id)|\(turn.hasConfirmedResult)|\(allowsAutoCollapse)") {
            defer { fadingProcess = false }
            guard processExpanded, turn.hasConfirmedResult, allowsAutoCollapse, !disclosure.wasManuallyToggled(turn.id), !inspectingTool else { return }
            let needsAttention = turn.processMessages.contains { $0.steps.contains { $0.status == .failed || $0.status == .waiting } }
            guard !needsAttention else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            guard allowsAutoCollapse, !disclosure.wasManuallyToggled(turn.id), !inspectingTool else { return }
            let stillNeedsAttention = turn.processMessages.contains { $0.steps.contains { $0.status == .failed || $0.status == .waiting } }
            guard turn.hasConfirmedResult, !stillNeedsAttention else { return }
            // Fade pixels briefly, then commit one height change. Animating the
            // whole subtree's height forces repeated table/text layout per frame.
            if !reduceMotion {
                withAnimation(.easeOut(duration: 0.14)) { fadingProcess = true }
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled, allowsAutoCollapse,
                  !disclosure.wasManuallyToggled(turn.id), !inspectingTool else { return }
            disclosure.collapse(turnID: turn.id)
        }
    }

    private var processTitle: String {
        let count = turn.processMessages.reduce(0) { $0 + $1.steps.count }
        let status: String = switch turn.state {
        case .completed: L10n.tr("已完成")
        case .interrupted: L10n.tr("已中断")
        case .failed: L10n.tr("执行失败")
        default: L10n.tr("执行过程")
        }
        return count > 0 ? L10n.tr("{0} · {1} 个步骤", "\(status)", "\(count)") : L10n.tr("{0} · 查看过程", "\(status)")
    }

    private func hasFollowingResponse(after id: String) -> Bool {
        if !turn.resultMessages.isEmpty { return true }
        guard let index = turn.processMessages.firstIndex(where: { $0.id == id }) else { return false }
        return turn.processMessages.dropFirst(index + 1).contains { $0.role == .assistant && !$0.text.isEmpty }
    }

    private var processContent: some View {
        ForEach(turn.processMessages) { message in
            MessageView(message: message, sessionID: sessionID, showsResponseActions: false,
                        hasFollowingResponse: hasFollowingResponse(after: message.id),
                        showsToolGroupSummary: !turn.canCollapseProcess || inspectingTool)
                .padding(.bottom, message.text.isEmpty ? 0 : 16).id(message.id)
        }
    }
}

struct TranscriptProcessSummary: View {
    let turn: TranscriptTurn
    let disclosure: TranscriptDisclosureState
    var body: some View {
        let expanded = disclosure.expanded(turnID: turn.id, defaultValue: !turn.defaultCollapsed)
        let steps = turn.processMessages.reduce(0) { $0 + $1.steps.count }
        Button { disclosure.toggle(turnID: turn.id, defaultValue: !turn.defaultCollapsed) } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet").frame(width: 22)
                Text(turn.state == .failed ? L10n.tr("执行失败") : turn.state == .interrupted ? L10n.tr("已中断") : L10n.tr("已完成"))
                if steps > 0 { Text(L10n.tr("· {0} 个步骤", "\(steps)")) }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 16)
            }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 28)
        }.buttonStyle(.plain).accessibilityValue(expanded ? L10n.tr("已展开") : L10n.tr("已折叠"))
            .accessibilityIdentifier("turn.process." + turn.id)
    }
}

struct TranscriptProcessMessage: View {
    let message: ChatMessage
    let sessionID: String
    let turnID: String
    let following: Bool
    let showsSummary: Bool
    let disclosure: TranscriptDisclosureState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        MessageView(message: message, sessionID: sessionID, hasFollowingResponse: following, showsToolGroupSummary: showsSummary)
            .opacity(disclosure.isFading(turnID) ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: disclosure.isFading(turnID))
            .onPreferenceChange(ToolInspectionPreferenceKey.self) { disclosure.inspect(messageID: message.id, open: $0) }
            .onDisappear { disclosure.inspect(messageID: message.id, open: false) }
    }
}

/// Owned by the conversation, not a recycled hosting cell. One delayed collapse
/// per turn; updates never animate the height of an entire tool/message subtree.
@MainActor @Observable
final class TranscriptDisclosureState {
    private var values: [String: Bool] = [:]
    private var manual: Set<String> = []
    private var fading: Set<String> = []
    private var inspectedMessages: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var taskTokens: [String: UUID] = [:]
    @ObservationIgnored private var currentTurns: [TranscriptTurn] = []
    @ObservationIgnored private var reduceMotion = false
    var allowsAutoCollapse = true
    func expanded(turnID: String, defaultValue: Bool) -> Bool { values[turnID] ?? defaultValue }
    func wasManuallyToggled(_ id: String) -> Bool { manual.contains(id) }
    func isFading(_ id: String) -> Bool { fading.contains(id) }
    func toggle(turnID: String, defaultValue: Bool) {
        tasks.removeValue(forKey: turnID)?.cancel(); taskTokens[turnID] = nil; fading.remove(turnID)
        values[turnID] = !expanded(turnID: turnID, defaultValue: defaultValue)
        manual.insert(turnID)
    }
    func inspect(messageID: String, open: Bool) {
        if open { inspectedMessages.insert(messageID) } else { inspectedMessages.remove(messageID) }
    }
    func collapse(turnID: String) { if !manual.contains(turnID) { values[turnID] = false } }
    func cancelScheduled() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); taskTokens.removeAll(); fading.removeAll()
    }
    private func eligible(_ turn: TranscriptTurn) -> Bool {
        allowsAutoCollapse && turn.hasConfirmedResult && !manual.contains(turn.id)
            && expanded(turnID: turn.id, defaultValue: false)
            && !turn.processMessages.contains { inspectedMessages.contains($0.id) || $0.steps.contains { $0.status == .failed || $0.status == .waiting } }
    }
    func synchronize(turns: [TranscriptTurn], allowsAutoCollapse: Bool, reduceMotion: Bool) {
        currentTurns = turns
        self.allowsAutoCollapse = allowsAutoCollapse
        self.reduceMotion = reduceMotion
        for turn in turns where values[turn.id] == nil { values[turn.id] = !turn.defaultCollapsed }
        let ids = Set(turns.map(\.id))
        for id in Array(tasks.keys) where !ids.contains(id) || !turns.contains(where: { $0.id == id && eligible($0) }) {
            tasks.removeValue(forKey: id)?.cancel(); taskTokens[id] = nil; fading.remove(id)
        }
        for turn in turns where eligible(turn) && tasks[turn.id] == nil {
            let id = turn.id
            let token = UUID()
            taskTokens[id] = token
            tasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled else { return }
                defer {
                    if self.taskTokens[id] == token {
                        self.tasks[id] = nil; self.taskTokens[id] = nil; self.fading.remove(id)
                    }
                }
                guard let latest = self.currentTurns.first(where: { $0.id == id }), self.eligible(latest) else { return }
                if !self.reduceMotion {
                    self.fading.insert(id)
                    try? await Task.sleep(for: .milliseconds(140))
                }
                guard !Task.isCancelled, self.eligible(latest) else { return }
                self.collapse(turnID: id)
            }
        }
    }
}
