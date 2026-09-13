import SwiftUI

/// One reply owns its progress disclosure and one final-answer action bar.
/// Message identity remains unchanged when the user expands saved work.
struct TranscriptTurnView: View {
    let turn: TranscriptTurn
    let sessionID: String
    @State private var processExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(turn.userMessages) { message in
                MessageView(message: message, sessionID: sessionID, showsResponseActions: false)
                    .padding(.bottom, 34).id(message.id)
            }
            if !turn.processMessages.isEmpty {
                if turn.canCollapseProcess {
                    DisclosureGroup(isExpanded: $processExpanded) {
                        processContent.padding(.top, 14)
                    } label: {
                        Text(processTitle)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .tint(.secondary)
                    .accessibilityIdentifier("turn.process.\(turn.id)")
                    .padding(.bottom, 22)
                } else {
                    processContent
                }
            }
            ForEach(turn.resultMessages) { message in
                MessageView(message: message, sessionID: sessionID,
                            showsResponseActions: turn.actionMessageID == message.id)
                    .padding(.bottom, 22).id(message.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: turn.isComplete) { _, complete in
            if complete { processExpanded = false }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: turn.canCollapseProcess)
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

    private var processContent: some View {
        ForEach(turn.processMessages) { message in
            MessageView(message: message, sessionID: sessionID, showsResponseActions: false)
                .padding(.bottom, 22).id(message.id)
        }
    }
}
