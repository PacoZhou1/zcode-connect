import SwiftUI

/// One reply owns its progress disclosure and one final-answer action bar.
/// Message identity remains unchanged when the user expands saved work.
struct TranscriptTurnView: View {
    let turn: TranscriptTurn
    let sessionID: String
    @State private var processExpanded = false

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
                        Text("查看执行过程")
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
    }

    private var processContent: some View {
        ForEach(turn.processMessages) { message in
            MessageView(message: message, sessionID: sessionID, showsResponseActions: false)
                .padding(.bottom, 22).id(message.id)
        }
    }
}
