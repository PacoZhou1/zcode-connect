import SwiftUI
import Observation

struct MessageView: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    let sessionID: String
    var showsResponseActions = false
    var hasFollowingResponse = false
    var showsToolGroupSummary = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var changesExpanded = true
    private var feedback: Int { store.localFeedback["\(sessionID)|\(message.id)"] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: message.text.isEmpty ? 0 : 8) {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 92)
                    VStack(alignment: .leading, spacing: 10) {
                        attachmentLabels
                        RichMessageText(text: message.text, user: true).equatable()
                    }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(ZTheme.userBubble, in: RoundedRectangle(cornerRadius: 23))
                        .contextMenu {
                            Button("复制", systemImage: "square.on.square") { store.copy(message.text) }
                            ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                }
            } else {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup {
                        Text(reasoning).font(.subheadline).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "brain").font(.system(size: 17)).frame(width: 22).accessibilityHidden(true)
                            Text("思考过程").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.font(.subheadline).foregroundStyle(.secondary)
                }
                if !message.steps.isEmpty {
                    ToolActivityGroup(steps: message.steps, initiallyExpanded: message.role == .tool,
                                      elapsed: message.elapsed, hasFollowingText: hasFollowingResponse || !message.text.isEmpty, showsSummary: showsToolGroupSummary)
                }
                if !message.text.isEmpty {
                    RichMessageText(text: message.text, user: false, streaming: message.isStreaming).equatable()
                        .transition(reduceMotion ? .identity : .opacity)
                }
                attachmentLabels
                if !message.changes.isEmpty {
                    changeSummary.padding(.top, -4)
                }
                if message.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在继续…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if message.role == .assistant && showsResponseActions && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    responseActions.padding(.top, -6)
                        .accessibilityIdentifier("message.responseActions.\(message.id)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .disclosureGroupStyle(CompactActivityDisclosureStyle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: message.text.isEmpty)
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
            if store.isReferenceMode || (message.forkTarget != nil && store.session(sessionID)?.canFork == true) {
                Button { store.forkSession(sessionID, target: message.forkTarget ?? (store.isReferenceMode ? MessageForkTarget(rowId: 0, entityId: message.id) : nil)) } label: {
                    BranchShareGlyph().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 16, height: 16)
                }.accessibilityLabel("从此回复创建分支")
                    .accessibilityIdentifier("message.fork.\(message.id)")
                    .disabled(store.isForking(sessionID))
            } else {
                ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享回复")
            }
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

enum MessageTextBlock: Identifiable, Equatable, Sendable {
    case prose(Int, AttributedString), code(Int, String), table(Int, [[String]])
    var id: Int {
        switch self { case .prose(let id, _), .code(let id, _), .table(let id, _): id }
    }
    static func layoutBlocks(_ blocks: [Self]) -> [Self] {
        blocks.filter { block in
            if case .prose(_, let content) = block { return !content.characters.isEmpty }
            return true
        }
    }
}

/// Exact-content cache: streaming revisions never reuse an older parse. NSCache
/// bounds resident history and releases it under memory pressure.
@MainActor
final class MessageTextCache {
    static let shared = MessageTextCache()
    private final class Entry: NSObject {
        let blocks: [MessageTextBlock]
        init(_ blocks: [MessageTextBlock]) { self.blocks = blocks }
    }
    private let cache: NSCache<NSString, Entry> = {
        let value = NSCache<NSString, Entry>()
        value.countLimit = 256
        value.totalCostLimit = 8 * 1024 * 1024
        return value
    }()
    // Separate, tightly bounded handoff cache: stream prefixes cannot evict
    // completed history, and a final-answer reparent can reuse its last parse.
    private let liveCache: NSCache<NSString, Entry> = {
        let value = NSCache<NSString, Entry>()
        value.countLimit = 8
        value.totalCostLimit = 2 * 1024 * 1024
        return value
    }()
    func cached(text: String, user: Bool) -> [MessageTextBlock]? {
        let key = ((user ? "u|" : "a|") + text) as NSString
        return cache.object(forKey: key)?.blocks ?? liveCache.object(forKey: key)?.blocks
    }
    func storeLive(_ blocks: [MessageTextBlock], text: String, user: Bool) {
        liveCache.setObject(Entry(blocks), forKey: ((user ? "u|" : "a|") + text) as NSString,
                           cost: text.utf16.count * 8 + 256)
    }
    func store(_ blocks: [MessageTextBlock], text: String, user: Bool) {
        cache.setObject(Entry(blocks), forKey: ((user ? "u|" : "a|") + text) as NSString,
                        cost: text.utf16.count * 8 + 256)
    }
    func blocks(text: String, user: Bool) -> [MessageTextBlock] {
        let key = ((user ? "u|" : "a|") + text) as NSString
        if let entry = cache.object(forKey: key) { return entry.blocks }
        let result = Self.parse(text: text, user: user)
        cache.setObject(Entry(result), forKey: key, cost: text.utf16.count * 8 + 256)
        return result
    }
    nonisolated private static func attributed(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .newlines)
        return (try? AttributedString(markdown: trimmed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(trimmed)
    }
    /// Foundation's CommonMark block parser owns syntax, including headings,
    /// lists, quotes and escaped delimiters. Inline runs retain their attributes.
    nonisolated private static func prose(_ text: String, start: Int) -> [MessageTextBlock] {
        guard let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) else {
            return [.prose(start, attributed(text))]
        }
        var blocks: [MessageTextBlock] = []
        var current = AttributedString()
        var identity: Int?
        for run in value.runs {
            let next = run.presentationIntent?.components.first?.identity
            if next != identity, !current.characters.isEmpty {
                blocks.append(.prose(start + blocks.count, current)); current = AttributedString()
            }
            identity = next
            current.append(AttributedString(value[run.range]))
        }
        if !current.characters.isEmpty { blocks.append(.prose(start + blocks.count, current)) }
        return blocks
    }

    nonisolated static func parse(text: String, user: Bool) -> [MessageTextBlock] {
        if user { return [.prose(0, attributed(text))] }
        let fence = String(repeating: String(UnicodeScalar(96)!), count: 3)
        let segments = text.components(separatedBy: fence)
        var result: [MessageTextBlock] = []
        for (index, segment) in segments.enumerated() {
            if index % 2 == 1 {
                let lines = segment.components(separatedBy: "\n")
                result.append(.code(result.count, lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)))
            } else {
                var pending: [String] = []
                var table: [[String]] = []
                for line in segment.components(separatedBy: "\n") {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        if !pending.isEmpty { result.append(contentsOf: prose(pending.joined(separator: "\n"), start: result.count)); pending = [] }
                        let cells = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
                        if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                    } else {
                        if !table.isEmpty { result.append(.table(result.count, table)); table = [] }
                        pending.append(line)
                    }
                }
                if !pending.isEmpty { result.append(contentsOf: prose(pending.joined(separator: "\n"), start: result.count)) }
                if !table.isEmpty { result.append(.table(result.count, table)) }
            }
        }
        return result
    }
}

struct MessageTextParseRequest: Equatable, Sendable {
    let text: String
    let user: Bool
}

/// Transient stream prefixes never enter the completed-message cache.
private actor StreamingMessageTextParser {
    static let shared = StreamingMessageTextParser()

    func parse(_ request: MessageTextParseRequest) async throws -> [MessageTextBlock] {
        try Task.checkCancellation()
        let blocks = MessageTextCache.parse(text: request.text, user: request.user)
        try Task.checkCancellation()
        return blocks
    }
}

@MainActor @Observable
final class StreamingMessageTextState {
    typealias Parser = @Sendable (MessageTextParseRequest) async throws -> [MessageTextBlock]
    private(set) var blocks: [MessageTextBlock] = []
    @ObservationIgnored private(set) var renderedRequest: MessageTextParseRequest?
    @ObservationIgnored private var latest: MessageTextParseRequest?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private let parser: Parser
    @ObservationIgnored private let interval: Duration

    init(interval: Duration = .milliseconds(50),
         parser: @escaping Parser = { try await StreamingMessageTextParser.shared.parse($0) }) {
        self.interval = interval
        self.parser = parser
    }

    func update(text: String, user: Bool) {
        let request = MessageTextParseRequest(text: text, user: user)
        guard latest != request else { return }
        latest = request
        guard task == nil else { return }
        let current = UUID()
        generation = current
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { task = nil } }
            while !Task.isCancelled, generation == current, let request = latest {
                let parsed: [MessageTextBlock]
                do { parsed = try await parser(request) }
                catch { return }
                guard !Task.isCancelled, generation == current, let newest = latest else { return }
                // Publish progress even while append-only output continues. A rewritten
                // or shortened answer cannot receive a result from its old content.
                if newest.user == request.user, newest.text.utf8.starts(with: request.text.utf8) {
                    blocks = parsed
                    renderedRequest = request
                    MessageTextCache.shared.storeLive(parsed, text: request.text, user: request.user)
                }
                // A fixed interval between batches, never restarted by incoming tokens.
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard latest != request else { return }
            }
        }
    }

    func cancel() {
        generation = nil
        task?.cancel()
        task = nil
        latest = nil
        renderedRequest = nil
        blocks = []
    }
}

struct RichMessageText: View, Equatable {
    var text: String
    var user: Bool
    var streaming = false

    var body: some View {
        StableRichMessageText(text: text, user: user, streaming: streaming)
    }
}

/// Keep one view identity through stream completion. A final event must not
/// replace measured text with a fresh 120pt parsing placeholder.
private struct StableRichMessageText: View {
    let text: String
    let user: Bool
    let streaming: Bool
    @State private var renderer = StreamingMessageTextState()
    @State private var completed: [MessageTextBlock] = []

    var body: some View {
        let blocks = streaming ? renderer.blocks : (MessageTextCache.shared.cached(text: text, user: user) ?? (completed.isEmpty ? renderer.blocks : completed))
        MessageTextContent(blocks: blocks, user: user)
            .frame(minHeight: blocks.isEmpty && !text.isEmpty ? 120 : nil, alignment: .topLeading)
            .task(id: StableTextRequest(text: text, user: user, streaming: streaming)) {
                if streaming { renderer.update(text: text, user: user); return }
                if let cached = MessageTextCache.shared.cached(text: text, user: user) { completed = cached; return }
                if renderer.renderedRequest == MessageTextParseRequest(text: text, user: user) {
                    completed = renderer.blocks
                    MessageTextCache.shared.store(completed, text: text, user: user)
                    return
                }
                let request = MessageTextParseRequest(text: text, user: user)
                let worker = Task.detached(priority: .userInitiated) {
                    MessageTextCache.parse(text: request.text, user: request.user)
                }
                let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                MessageTextCache.shared.store(parsed, text: request.text, user: request.user)
                completed = parsed
            }
            .onDisappear { renderer.cancel() }
    }
}

private struct StableTextRequest: Equatable {
    let text: String
    let user: Bool
    let streaming: Bool
}

private struct MessageTextContent: View {
    let blocks: [MessageTextBlock]
    let user: Bool
    @ViewBuilder private var rows: some View {
        ForEach(MessageTextBlock.layoutBlocks(blocks)) { block in
            MessageTextBlockRow(block: block, user: user).equatable()
        }
    }
    var body: some View {
        // Only the transcript virtualizes. A message has one stable height.
        VStack(alignment: .leading, spacing: 12) { rows }
    }
}

/// Full block values participate in equality: an unchanged ID alone must not
/// retain an old streaming tail, Markdown attributes, or role-dependent style.
private struct MessageTextBlockRow: View, Equatable {
    let block: MessageTextBlock
    let user: Bool

    private func proseFont(_ text: AttributedString) -> Font {
        for component in text.runs.first?.presentationIntent?.components ?? [] {
            if case .header(let level) = component.kind { return level <= 2 ? .title3.bold() : .headline }
        }
        return .body
    }
    private func quoteDepth(_ text: AttributedString) -> Int {
        (text.runs.first?.presentationIntent?.components ?? []).filter { $0.kind == .blockQuote }.count
    }
    private func listMarker(_ text: AttributedString) -> String? {
        let components = text.runs.first?.presentationIntent?.components ?? []
        let ordered = components.contains { $0.kind == .orderedList }
        for component in components {
            if case .listItem(let ordinal) = component.kind { return ordered ? "\(ordinal)." : "•" }
        }
        return nil
    }

    var body: some View {
        switch block {
        case .prose(_, let content):
            if !content.characters.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let marker = listMarker(content) { Text(marker).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing) }
                    Text(content)
                        .font(proseFont(content)).tracking(user ? 0 : 0.3)
                        .lineSpacing(4)
                        .foregroundStyle(user ? ZTheme.userText : .primary)
                        .frame(maxWidth: user ? nil : .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.leading, quoteDepth(content) > 0 ? 12 : 0)
                .overlay(alignment: .leading) {
                    if quoteDepth(content) > 0 { Rectangle().fill(.quaternary).frame(width: 3) }
                }
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

/// Content rows use native disclosures, not navigation glass or decorative cards.
private struct ToolActivityGroup: View {
    let steps: [ToolStep]
    let elapsed: String?
    let hasFollowingText: Bool
    let showsSummary: Bool
    @State private var expanded: Bool
    @State private var manuallyToggled = false
    @State private var inspectingTool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var completionReady: Bool { hasFollowingText && steps.allSatisfy { $0.status == .completed } }

    init(steps: [ToolStep], initiallyExpanded: Bool, elapsed: String?, hasFollowingText: Bool, showsSummary: Bool) {
        self.steps = steps; self.elapsed = elapsed; self.hasFollowingText = hasFollowingText; self.showsSummary = showsSummary
        _expanded = State(initialValue: (initiallyExpanded && !(hasFollowingText && steps.allSatisfy { $0.status == .completed })) || steps.contains { $0.status == .running || $0.status == .failed || $0.status == .waiting })
    }
    private var commands: Int { steps.filter { $0.activityKind == .command }.count }
    private var summary: String {
        let active = steps.filter { $0.status == .running }.count
        let failures = steps.filter { $0.status == .failed }.count
        let waiting = steps.filter { $0.status == .waiting }.count
        if active > 0 { return "正在执行 · \(active) 项进行中，共 \(steps.count) 项" }
        if waiting > 0 { return "等待确认 · \(waiting) 项" }
        if failures > 0 { return "执行记录 · \(failures) 项未完成，共 \(steps.count) 项" }
        if steps.contains(where: { $0.status == .idle }) { return "执行记录 · \(steps.count) 项" }
        if commands == steps.count { return "已运行 \(commands) 条命令" }
        if commands == 0 { return "已调用 \(steps.count) 个工具" }
        return "已运行 \(commands) 条命令，调用 \(steps.count - commands) 个工具"
    }
    var body: some View {
        Group {
            if !showsSummary {
                VStack(alignment: .leading, spacing: 0) { ForEach(steps) { ToolActivityRow(step: $0) } }
            } else if steps.count == 1, let step = steps.first {
                ToolActivityRow(step: step)
            } else {
                DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { manuallyToggled = true; expanded = $0 })) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(steps) { ToolActivityRow(step: $0) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: commands == steps.count ? "terminal" : "list.bullet")
                            .font(.system(size: 17, weight: .regular)).frame(width: 22).accessibilityHidden(true)
                        Text(summary).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 28)
                        .accessibilityIdentifier("message.toolSteps")
                }
                .tint(.secondary)
                .onPreferenceChange(ToolInspectionPreferenceKey.self) { inspectingTool = $0 }
                .onChange(of: completionReady) { _, ready in
                    if ready, !manuallyToggled, !inspectingTool {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { expanded = false }
                    }
                }
            }
            if let elapsed, !elapsed.isEmpty {
                Text("总用时 \(elapsed)").font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
        }
    }
}

private struct ToolActivityRow: View {
    let step: ToolStep
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(step.detail.isEmpty ? "没有更多详情" : step.detail)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 30).padding(.vertical, 8)
                .foregroundStyle(.secondary)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon.frame(width: 22, height: 20)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(step.activityStatus).fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true).layoutPriority(1)
                        .foregroundStyle(step.status == .failed ? Color.red : Color.secondary)
                    if !step.activitySummary.isEmpty {
                        Text(step.activitySummary)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                            .truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .preference(key: ToolInspectionPreferenceKey.self, value: expanded)
        .accessibilityIdentifier("tool.activity." + step.id)
        .accessibilityHint("展开查看完整输入与输出")
    }
    @ViewBuilder private var icon: some View {
        if step.activityKind == .webFetch, let url = step.faviconURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                placeholder: { Image(systemName: step.activityKind.symbol).font(.system(size: 17, weight: .regular)) }
        } else { Image(systemName: step.activityKind.symbol).font(.system(size: 17, weight: .regular)) }
    }
}

struct ToolInspectionPreferenceKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// One row rhythm for reasoning, tool summaries and individual tools.
private struct CompactActivityDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 16)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }.frame(minHeight: 28).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
            if configuration.isExpanded { configuration.content.transition(.opacity) }
        }
    }
}
