import SwiftUI

struct MessageView: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    let sessionID: String
    @State private var showSteps = false
    @State private var changesExpanded = true
    private var feedback: Int { store.localFeedback["\(sessionID)|\(message.id)"] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 92)
                    VStack(alignment: .leading, spacing: 10) {
                        attachmentLabels
                        RichMessageText(text: message.text, user: true)
                    }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(ZTheme.userBubble, in: RoundedRectangle(cornerRadius: 23))
                        .contextMenu {
                            Button("复制", systemImage: "square.on.square") { store.copy(message.text) }
                            ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                }
            } else {
                if let elapsed = message.elapsed {
                    Button { withAnimation { showSteps.toggle() } } label: {
                        HStack(spacing: 8) {
                            Text("用时 \(elapsed)")
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                                .rotationEffect(.degrees(showSteps ? 90 : 0))
                        }.font(.system(size: 17)).foregroundStyle(.secondary)
                    }.padding(.bottom, 0)
                    Divider()
                } else if !message.steps.isEmpty {
                    Button { withAnimation { showSteps.toggle() } } label: {
                        Label("执行过程 · \(message.steps.count) 个步骤",
                              systemImage: showSteps ? "chevron.down" : "chevron.right")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("message.toolSteps")
                }
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("思考过程") {
                        Text(reasoning).font(.subheadline).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.subheadline).foregroundStyle(.secondary)
                }
                if showSteps || message.role == .tool || message.steps.contains(where: { $0.status == .running }) {
                    ForEach(message.steps) { step in
                        DisclosureGroup {
                            Text(step.detail).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Label(step.title, systemImage: step.status == .running ? "circle.dotted" :
                                  step.status == .failed ? "exclamationmark.circle" : "checkmark.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                RichMessageText(text: message.text, user: false)
                attachmentLabels
                if !message.changes.isEmpty {
                    changeSummary.padding(.top, -4)
                }
                if message.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在继续…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if message.role == .assistant {
                    responseActions.padding(.top, -6)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attachmentLabels: some View {
        ForEach(message.attachments) { attachment in
            MessageAttachmentView(attachment: attachment)
        }
    }

    private var changeSummary: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { changesExpanded.toggle() } } label: {
                HStack {
                    Text("已更改 \(message.changes.count) 个文件").font(.system(size: 14, weight: .medium))
                    ChangeCount(additions: message.changes.reduce(0) { $0 + $1.additions },
                                deletions: message.changes.reduce(0) { $0 + $1.deletions })
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                        .rotationEffect(.degrees(changesExpanded ? 0 : -90))
                }.padding(.horizontal, 16).frame(height: 34)
            }.buttonStyle(.plain)
            if changesExpanded {
                Divider()
                ForEach(message.changes) { change in
                    Button { store.sheet = .files(sessionID, true) } label: {
                        HStack {
                            Text(change.path).font(.system(size: 13)).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 12)
                            ChangeCount(additions: change.additions, deletions: change.deletions)
                        }.padding(.horizontal, 16).frame(height: 34)
                    }.buttonStyle(.plain).background(Color(uiColor: .systemGray5))
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19))
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(ZTheme.separator, lineWidth: 0.5))
    }

    private var responseActions: some View {
        HStack(spacing: 11) {
            Button { store.copy(message.text) } label: { Image(systemName: "square.on.square") }
                .accessibilityLabel("复制回复")
            Button { store.toggleLocalFeedback(1, messageID: message.id, sessionID: sessionID) } label: {
                Image(systemName: feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
            }.accessibilityLabel("有帮助")
            Button { store.toggleLocalFeedback(-1, messageID: message.id, sessionID: sessionID) } label: {
                Image(systemName: feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }.accessibilityLabel("没有帮助")
            ShareLink(item: message.text) { BranchShareGlyph().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 16, height: 16) }
                .accessibilityLabel("分享回复")
            if store.showTimestamps {
                Text(timestampLabel)
                    .font(.system(size: 13))
            }
            Spacer()
        }.font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary)
            .buttonStyle(.plain).padding(.vertical, 2)
    }

    private var timestampLabel: String {
        guard store.isReferenceMode else { return message.createdAt.formatted(date: .omitted, time: .shortened) }
        switch message.id {
        case "preview-previous": return "10:32"
        case "preview-answer": return "10:40"
        case "ref-assistant-1": return "星期五 19:04"
        default: return "星期五 21:53"
        }
    }
}

struct RichMessageText: View {
    var text: String
    var user: Bool

    private enum Block: Identifiable {
        case prose(Int, String), code(Int, String), table(Int, [[String]])
        var id: Int {
            switch self { case .prose(let id, _), .code(let id, _), .table(let id, _): id }
        }
    }

    private var blocks: [Block] {
        if user { return [.prose(0, text)] }
        let fence = String(repeating: String(UnicodeScalar(96)!), count: 3)
        let segments = text.components(separatedBy: fence)
        var result: [Block] = []
        for (index, segment) in segments.enumerated() {
            if index % 2 == 1 {
                let lines = segment.components(separatedBy: "\n")
                result.append(.code(result.count, lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)))
            } else {
                var pending: [String] = []
                var table: [[String]] = []
                for line in segment.components(separatedBy: "\n") {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        if !pending.isEmpty { result.append(.prose(result.count, pending.joined(separator: "\n"))); pending = [] }
                        let cells = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
                        if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                    } else {
                        if !table.isEmpty { result.append(.table(result.count, table)); table = [] }
                        pending.append(line)
                    }
                }
                if !pending.isEmpty { result.append(.prose(result.count, pending.joined(separator: "\n"))) }
                if !table.isEmpty { result.append(.table(result.count, table)) }
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .prose(_, let content):
                    let trimmed = content.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty {
                        Text((try? AttributedString(markdown: trimmed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(trimmed))
                            .font(.system(size: 17)).tracking(user ? 0 : 0.6)
                            .lineSpacing(5.333333)
                            .foregroundStyle(user ? ZTheme.userText : .primary)
                            .frame(maxWidth: user ? nil : .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                case .code(_, let content):
                    CodeBlockView(code: content)
                case .table(_, let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                HStack(alignment: .top, spacing: 20) {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Text(cell).font(.system(size: 16, weight: index == 0 ? .semibold : .regular))
                                            .frame(width: 150, alignment: .leading)
                                    }
                                }.padding(.vertical, 14)
                                Divider()
                            }
                        }
                    }.padding(.vertical, 8).accessibilityLabel("数据表格，可横向滚动")
                }
            }
        }
    }
}

struct CodeBlockView: View {
    @Environment(AppStore.self) private var store
    let code: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("代码").font(.caption)
                Spacer()
                Button { store.copy(code) } label: { Label("复制", systemImage: "square.on.square").font(.caption) }
            }.padding(12).foregroundStyle(.secondary)
            Divider()
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
