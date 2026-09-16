import SwiftUI

/// One reply owns its progress disclosure and one final-answer action bar.
/// Message identity remains unchanged when the user expands saved work.
struct TranscriptTurnView: View {
    let turn: TranscriptTurn
    let sessionID: String
    var allowsAutoCollapse = true
    @State private var processExpanded: Bool

    init(turn: TranscriptTurn, sessionID: String, allowsAutoCollapse: Bool = true) {
        self.turn = turn
        self.sessionID = sessionID
        self.allowsAutoCollapse = allowsAutoCollapse
        _processExpanded = State(initialValue: !turn.defaultCollapsed)
    }
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
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { processExpanded.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "list.bullet").font(.system(size: 17, weight: .regular)).frame(width: 22).accessibilityHidden(true)
                                Text(processTitle)
                                Spacer(minLength: 8)
                                Image(systemName: processExpanded ? "chevron.down" : "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 16)
                            }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 28)
                        }.buttonStyle(.plain)
                            .accessibilityValue(processExpanded ? "已展开" : "已折叠")
                            .accessibilityIdentifier("turn.process.\(turn.id)")
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                    if processExpanded {
                        processContent.transition(reduceMotion ? .identity : .opacity)
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
        .onChange(of: turn.hasConfirmedResult) { _, complete in
            let needsAttention = turn.processMessages.contains { $0.steps.contains { $0.status == .failed || $0.status == .waiting } }
            if complete, allowsAutoCollapse, !inspectingTool, !needsAttention {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { processExpanded = false }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: turn.hasConfirmedResult)
    }

    private var processTitle: String {
        let count = turn.processMessages.reduce(0) { $0 + $1.steps.count }
        let status: String = switch turn.state {
        case .completed: "已完成"
        case .interrupted: "已中断"
        case .failed: "执行失败"
        default: "执行过程"
        }
        return count > 0 ? "\(status) · \(count) 个步骤" : "\(status) · 查看过程"
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
