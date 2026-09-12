import SwiftUI

struct InteractionRequestCard: View {
    @Environment(AppStore.self) private var store
    let interaction: PendingInteraction
    @State private var busy = false
    @State private var showHookReview = false
    @State private var selections: [String: Set<String>] = [:]
    @State private var otherAnswers: [String: String] = [:]
    @State private var feedback = ""
    @State private var loadedDraftScope: String?
    private struct AnswerDraft: Codable {
        var signature: [String]
        var selections: [String: Set<String>]
        var otherAnswers: [String: String]
        var feedback: String
    }
    private var draftKey: String { "answer:\(interaction.sessionId):\(interaction.id)" }
    private var draftScope: String {
        store.isReferenceMode ? "reference" : "\(store.activeProfileID ?? "")|\(store.activeProfile?.baseURL ?? "")"
    }
    private var questionSignature: [String] {
        [interaction.kind, interaction.title, interaction.toolName ?? "", interaction.reason ?? "", interaction.input?.formatted ?? ""] + questions.flatMap { question in
            [question.id, question.question, String(question.multiSelect ?? false)] +
            (question.options ?? []).flatMap { [$0.label, $0.value ?? "", $0.description ?? ""] }
        }
    }


    private var requiresDesktop: Bool { interaction.kind == "workspaceHookReview" }
    private var isPermission: Bool { interaction.kind == "permission" }
    private var isPlan: Bool { interaction.toolName == "ExitPlanMode" }
    private var questions: [PendingInteraction.Question] { interaction.questions ?? [] }
    private var trimmedFeedback: String { feedback.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAnswer: Bool {
        if isPermission || isPlan { return true }
        if questions.isEmpty { return !trimmedFeedback.isEmpty }
        return questions.allSatisfy { question in
            !(selections[question.id] ?? []).isEmpty ||
            !(otherAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(requiresDesktop ? "需要审查工作区命令" : isPermission ? "需要你的批准" : isPlan ? "确认方案" : "需要你的回答",
                  systemImage: requiresDesktop ? "terminal" : isPermission ? "hand.raised" : isPlan ? "list.bullet.clipboard" : "text.bubble")
                .font(.headline)
            if interaction.title != interaction.toolName { Text(interaction.title).font(.body) }
            if let reason = interaction.reason, !reason.isEmpty, !reason.hasPrefix("Tool ") {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            if requiresDesktop {
                if interaction.hookReview != nil {
                    Text("工作区命令需要逐项审查。信任会持久保存，不能按一次性审批处理。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("审查工作区命令") { showHookReview = true }
                        .buttonStyle(NativeGlassButtonStyle()).accessibilityIdentifier("hooks.openReview")
                } else {
                    Label("此操作需要在电脑端确认，请回到 ZCode 处理。", systemImage: "desktopcomputer")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if isPlan {
                if let plan = interaction.input?.objectValue?["plan"]?.stringValue, !plan.isEmpty {
                    DisclosureGroup("查看完整方案") {
                        Text(plan).font(.subheadline).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
                TextField("需要调整？在这里写下修改意见", text: $feedback, axis: .vertical)
                    .lineLimit(2...6).padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("interaction.feedback")
            } else if isPermission {
                if let input = interaction.input {
                    DisclosureGroup("操作详情") {
                        Text(input.formatted).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.subheadline)
                }
            } else if !questions.isEmpty {
                ForEach(questions) { question in questionForm(question) }
            } else {
                TextField("填写回答", text: $feedback, axis: .vertical).lineLimit(2...6)
                    .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("interaction.answer")
            }
            if !requiresDesktop {
            HStack(spacing: 14) {
                Button(isPermission ? "拒绝" : isPlan ? "暂不执行" : "跳过", role: .destructive) {
                    submit(accept: false)
                }.buttonStyle(NativeGlassButtonStyle())
                Spacer(minLength: 0)
                if busy { ProgressView() }
                Button(isPermission ? "允许本次" : isPlan ? (trimmedFeedback.isEmpty ? "批准并执行" : "发送修改意见") : "提交回答") {
                    submit(accept: true)
                }.buttonStyle(.glassProminent).disabled(!canAnswer)
                    .accessibilityIdentifier("interaction.submit")
            }
            }
        }
        .disabled(busy)
        .padding(18)
        .background(isPermission ? Color.orange.opacity(0.08) : ZTheme.accent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showHookReview) {
            WorkspaceHookReviewSheet(sessionID: interaction.sessionId, interactionID: interaction.id)
        }
        .onAppear { restoreAnswerDraft() }
        .onChange(of: [draftScope, draftKey] + questionSignature) { restoreAnswerDraft() }
        .onChange(of: selections) { persistAnswerDraft() }
        .onChange(of: otherAnswers) { persistAnswerDraft() }
        .onChange(of: feedback) { persistAnswerDraft() }
    }

    private func restoreAnswerDraft() {
        loadedDraftScope = nil
        selections = [:]; otherAnswers = [:]; feedback = ""
        if let raw = store.drafts[draftKey]?.data(using: .utf8),
           let draft = try? JSONDecoder().decode(AnswerDraft.self, from: raw),
           draft.signature == questionSignature {
            selections = draft.selections; otherAnswers = draft.otherAnswers; feedback = draft.feedback
        }
        loadedDraftScope = draftScope
    }

    private func persistAnswerDraft() {
        guard loadedDraftScope == draftScope else { return }
        let draft = AnswerDraft(signature: questionSignature, selections: selections,
                                otherAnswers: otherAnswers, feedback: feedback)
        guard let data = try? JSONEncoder().encode(draft), let raw = String(data: data, encoding: .utf8) else { return }
        store.setDraft(raw, for: draftKey)
    }

    private func questionForm(_ question: PendingInteraction.Question) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = question.header, !header.isEmpty {
                Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(question.question).font(.body.weight(.medium))
            if question.multiSelect == true { Text("可多选").font(.caption).foregroundStyle(.secondary) }
            ForEach(question.options ?? []) { option in
                let value = option.value ?? option.label
                let selected = selections[question.id]?.contains(value) == true
                Button {
                    if question.multiSelect == true {
                        var values = selections[question.id] ?? []
                        if selected { values.remove(value) } else { values.insert(value) }
                        selections[question.id] = values
                    } else {
                        selections[question.id] = [value]
                        otherAnswers[question.id] = ""
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: question.multiSelect == true
                              ? (selected ? "checkmark.square.fill" : "square")
                              : (selected ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(selected ? ZTheme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label).foregroundStyle(.primary)
                            if let detail = option.description {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
            TextField(question.options?.isEmpty == false ? "或填写你的回答" : "填写回答",
                text: Binding(get: { otherAnswers[question.id] ?? "" }, set: { value in
                    otherAnswers[question.id] = value
                    if question.multiSelect != true && !value.isEmpty { selections[question.id] = [] }
                }), axis: .vertical)
                .lineLimit(1...5).padding(12).background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func submit(accept: Bool) {
        busy = true
        Task {
            if isPermission { await store.respond(interaction, allow: accept) }
            else {
                let content: JSONValue?
                if !accept { content = nil }
                else if isPlan { content = .object(["answer": .string(trimmedFeedback.isEmpty ? "approve" : trimmedFeedback)]) }
                else if questions.isEmpty { content = .object(["answer": .string(trimmedFeedback)]) }
                else {
                    var answers: [String: JSONValue] = [:]
                    for question in questions {
                        let selected = selections[question.id] ?? []
                        var values = (question.options ?? []).map { $0.value ?? $0.label }.filter { selected.contains($0) }
                        let other = (otherAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !other.isEmpty { values.append(other) }
                        answers[question.question] = question.multiSelect == true
                            ? .array(values.map(JSONValue.string)) : .string(values.first ?? "")
                    }
                    content = .object(["answers": .object(answers)])
                }
                let scope = draftScope, key = draftKey
                let submittedDraft = store.drafts[key]
                let accepted = await store.answer(interaction, content: content, decline: !accept)
                if accepted, scope == draftScope, store.drafts[key] == submittedDraft { store.setDraft("", for: key) }
            }
            busy = false
        }
    }
}
