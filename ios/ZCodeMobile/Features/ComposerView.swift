import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    let sessionID: String?
    var initiallyFocused = false
    var dismissOverlaysSignal = 0
    var onReasoningVisibilityChange: (Bool) -> Void = { _ in }
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var attachmentDraftIdentity = ""
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showAttachmentMenu = false
    @State private var attachmentContentHeight: CGFloat = 360
    @State private var pendingAttachmentAction: (() -> Void)?
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var showPermissions = false
    @State private var showContext = false
    @State private var showReasoning = false
    @State private var showGoalEditor = false
    @State private var submitting = false
    @State private var reasoningDraft: ReasoningLevel = .high
    @State private var dialActivation = 0
    @State private var confirmPlanExit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var speech = SpeechCapture()
    @State private var voicePhase = InlineVoicePhase.idle
    @State private var voiceAttempt = UUID()
    @State private var voiceTask: Task<Void, Never>?
    @State private var revealedVoiceText = false
    private var voiceActive: Bool { voicePhase != .idle }

    private var draftKey: String { sessionID ?? "new:\(store.selectedProjectID ?? "")" }
    private var draftIdentity: String {
        "\(store.isReferenceMode)|\(store.activeProfileID ?? "unconnected")|\(store.activeProfile?.baseURL ?? "")|\(draftKey)"
    }
    private var expanded: Bool { showContext || focused || !text.isEmpty || !attachments.isEmpty || sessionID == nil }
    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !submitting
            && !isRunning && (sessionID.map { !store.sendingSessions.contains($0) } ?? true)
            && attachmentDraftIdentity == draftIdentity && store.connection.isOnline && (sessionID == nil || store.session(sessionID!)?.canControl == true)
    }
    private var isRunning: Bool { sessionID.flatMap { store.session($0) }.map { [.running, .waiting].contains($0.status) } ?? false }
    private var permission: PermissionMode { store.permission(for: sessionID) }
    private var isPlanMode: Bool { store.isPlanMode(for: sessionID) }
    private var showsReferenceDocuments: Bool {
        #if DEBUG
        // Visual QA only: exercise the real five-row shape without connecting a host.
        if ProcessInfo.processInfo.arguments.contains("--attachment-five-row-review") { return false }
        #endif
        return store.isReferenceMode
    }

    var body: some View {
        VStack(spacing: 8) {
            if let id = sessionID, let usage = store.contextUsage[id] {
                CompactionStatusView(compaction: usage.compaction)
            }
            if let pending = store.pendingSubmissions[draftKey], !submitting {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("上一条消息尚未确认送达").font(.caption.weight(.medium))
                        Text(pending.text.isEmpty ? "\(pending.attachments.count) 个附件" : pending.text)
                            .font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("重试发送") { submit(retryPending: true) }
                        .font(.caption.weight(.semibold)).disabled(submitting)
                        .accessibilityIdentifier("composer.retryPending")
                }.padding(12).background(ZTheme.grouped, in: RoundedRectangle(cornerRadius: 16))
            }
            ZStack(alignment: .bottom) {
                inputSurface
                    .opacity(showReasoning ? 0.001 : 1)
                    .accessibilityHidden(showReasoning)
                if showReasoning {
                    reasoningPanel
                }
            }
        }
        .padding(.horizontal, expanded ? 12 : 38)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showReasoning)
        .task {
            text = store.drafts[draftKey] ?? ""
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            let screen = args.firstIndex(of: "--screen").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            if ["keyboard", "reasoning", "permissions", "context-empty-review"].contains(screen ?? "") { focused = true }
            if screen == "reasoning" { showReasoning = true }
            if screen == "voice", store.isReferenceMode {
                focused = true
                try? await Task.sleep(for: .milliseconds(350))
                voicePhase = .recording
                speech.text = "这是一条语音输入验收消息。"
                voiceTask = Task {
                    var sample = 0
                    while !Task.isCancelled, voicePhase == .recording {
                        // Explicit visual-reference fixture; production samples only microphone audio.
                        let envelope = max(0, sin(Double(sample) * 0.055))
                        speech.levels.append(Float(envelope * (0.45 + 0.5 * abs(sin(Double(sample) * 0.37)))))
                        if speech.levels.count > 100 { speech.levels.removeFirst() }
                        sample += 1
                        try? await Task.sleep(for: .milliseconds(24))
                    }
                }
            }
            if screen == "permissions" {
                try? await Task.sleep(for: .milliseconds(300))
                showPermissions = true
            }
            #endif
            if initiallyFocused { focused = true }
            if let sessionID { await store.loadSettings(sessionID) }
            reasoningDraft = currentReasoning
        }
        .task(id: draftIdentity) {
            let identity = draftIdentity, key = draftKey
            attachments = store.draftAttachments[key] ?? []
            attachmentDraftIdentity = ""
            await store.loadDraftAttachments(for: key)
            guard identity == draftIdentity else { return }
            attachments = store.draftAttachments[key] ?? []
            attachmentDraftIdentity = identity
        }
        .onChange(of: draftIdentity) { _, _ in
            cancelInlineVoice()
            showContext = false
            pendingAttachmentAction = nil
            showAttachmentMenu = false
        }
        .onChange(of: attachments) { _, values in
            guard attachmentDraftIdentity == draftIdentity, store.draftAttachments[draftKey] != values else { return }
            store.setDraftAttachments(values, for: draftKey)
        }
        .onChange(of: showReasoning) { _, visible in
            onReasoningVisibilityChange(visible)
            if !visible { dialActivation += 1 }
        }
        .onChange(of: currentReasoning) { _, _ in if !showReasoning { dialActivation += 1 } }
        .onChange(of: dismissOverlaysSignal) { _, _ in
            showReasoning = false
            showContext = false
            showAttachmentMenu = false
        }
        .onDisappear {
            onReasoningVisibilityChange(false); cancelInlineVoice()
            pendingAttachmentAction = nil; showAttachmentMenu = false; showContext = false
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancelInlineVoice() } }
        .onChange(of: speech.isRecording) { _, recording in
            if !recording, voicePhase == .recording { finishInlineVoice(sendAfter: false) }
        }
        .onChange(of: text) { _, value in store.setDraft(value, for: draftKey) }
        .onChange(of: draftKey) { _, key in
            cancelInlineVoice()
            text = store.drafts[key] ?? ""
            attachmentDraftIdentity = ""
            attachments = store.draftAttachments[key] ?? []
        }
        .onChange(of: store.drafts[draftKey]) { _, value in
            if let value, value != text { text = value }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoSelections, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoSelections) { _, items in
            let identity = draftIdentity
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        guard identity == draftIdentity else { return }
                        let type = item.supportedContentTypes.first ?? .jpeg
                        addAttachment(data: data, name: "照片.\(type.preferredFilenameExtension ?? "jpg")",
                                      mime: type.preferredMIMEType ?? "image/jpeg")
                    }
                }
                photoSelections = []
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                    guard (values.fileSize ?? 0) <= 8 * 1024 * 1024 else {
                        store.errorMessage = "请选择小于 8 MB 的文件。"; continue
                    }
                    let data = try Data(contentsOf: url)
                    addAttachment(data: data, name: url.lastPathComponent,
                                  mime: values.contentType?.preferredMIMEType ?? "application/octet-stream")
                }
            } catch { store.errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in
                if let data { addAttachment(data: data, name: "拍摄照片.jpg", mime: "image/jpeg") }
            }.ignoresSafeArea()
        }
        .sheet(isPresented: $showGoalEditor) {
            GoalEditorView(sessionID: sessionID)
        }
        .confirmationDialog("关闭计划模式并恢复完全访问？", isPresented: $confirmPlanExit, titleVisibility: .visible) {
            Button("恢复完全访问", role: .destructive) { setPlanMode(false, confirmed: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此任务将可以直接编辑文件和运行命令，不再逐次请求批准。")
        }
    }

    private var inputSurface: some View {
        VStack(alignment: .leading, spacing: expanded ? 10 : 0) {
            if !attachments.isEmpty && !voiceActive {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                Text(attachment.name).font(.caption).lineLimit(1)
                                Button { attachments.removeAll { $0.id == attachment.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.accessibilityLabel("移除 \(attachment.name)")
                            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if !expanded && !voiceActive { attachmentMenu }
                inputField.frame(minHeight: expanded ? 28 : 34, alignment: expanded ? .top : .center)
                if !expanded && !voiceActive {
                    microphoneButton
                    primaryButton
                }
            }
            if expanded && !voiceActive {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        attachmentMenu
                        permissionButton
                        if isPlanMode {
                            Text("计划").font(.caption).foregroundStyle(ZTheme.accent)
                        }
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 8) {
                        if store.showContextUsage, let id = sessionID, let usage = store.contextUsage[id] {
                            ContextUsageButton(usage: usage, presented: $showContext)
                        }
                        reasoningButton
                        microphoneButton
                        primaryButton.padding(.leading, 5)
                    }
                }
                .padding(.leading, -3)
                .padding(.trailing, -7)
            }
        }
        .padding(.horizontal, expanded ? 14 : 12)
        .padding(.top, expanded ? 12 : 7)
        .padding(.bottom, expanded ? 8 : 7)
        .opacity(voiceActive ? 0 : 1)
        .animation(nil, value: voiceActive)
        .allowsHitTesting(!voiceActive)
        .accessibilityHidden(voiceActive)
        .frame(height: voiceActive ? 48 : nil, alignment: .bottom)
        .overlay(alignment: .bottom) {
            if voiceActive {
                InlineVoiceControls(capture: speech, phase: voicePhase,
                                    cancel: cancelInlineVoice,
                                    finish: { finishInlineVoice(sendAfter: false) },
                                    send: { finishInlineVoice(sendAfter: true) })
                    .transition(.identity)
            }
        }
        .glassEffect(ZTheme.controlGlass, in: RoundedRectangle(cornerRadius: voiceActive ? 24 : expanded ? 27 : 30))
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.9), value: voiceActive)
        .measureLayout("composer.surface")
        .tint(ZTheme.accent)
    }

    private var inputField: some View {
        let reduced = reduceMotion
        return TextField("在 \(store.hostName) 上工作", text: $text,
                         prompt: Text("在 \(store.hostName) 上工作").foregroundStyle(Color(uiColor: .placeholderText)), axis: .vertical)
            .font(.system(size: 17))
            .lineLimit(expanded ? 1...6 : 1...1)
            .focused($focused)
            .tint(ZTheme.accent)
            .accessibilityIdentifier("composer.text").accessibilityHidden(voiceActive)
            .keyframeAnimator(initialValue: 0.0, trigger: revealedVoiceText) { content, progress in
                content.opacity(1 - progress).offset(y: reduced ? 0 : 7 * progress)
            } keyframes: { _ in
                MoveKeyframe(0.65)
                CubicKeyframe(0, duration: 0.28)
            }
    }

    private var microphoneButton: some View {
        Button {
            startInlineVoice()
        } label: {
            Image(systemName: "mic").font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.primary).frame(width: 32, height: 34)
        }.disabled(submitting || isRunning)
            .accessibilityLabel("语音输入").accessibilityIdentifier("composer.microphone").accessibilityHidden(voiceActive)
    }

    private func startInlineVoice() {
        guard !voiceActive, !submitting, !isRunning else { return }
        voiceTask?.cancel()
        let attempt = UUID(), identity = draftIdentity
        voiceAttempt = attempt
        showReasoning = false
        showAttachmentMenu = false
        voicePhase = .preparing
        store.haptic()
        voiceTask = Task {
            await speech.start()
            guard voiceAttempt == attempt, draftIdentity == identity, !Task.isCancelled else { return }
            if let error = speech.error {
                voicePhase = .idle
                store.errorMessage = error
            } else { voicePhase = .recording }
        }
    }

    private func cancelInlineVoice() {
        voiceAttempt = UUID()
        voiceTask?.cancel()
        voiceTask = nil
        speech.stop()
        voicePhase = .idle
    }

    private func finishInlineVoice(sendAfter: Bool) {
        guard voicePhase == .recording else { return }
        let attempt = voiceAttempt, identity = draftIdentity
        voicePhase = .transcribing
        voiceTask = Task {
            let started = ContinuousClock.now
            let transcript = await speech.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            let remaining = Duration.milliseconds(180) - started.duration(to: ContinuousClock.now)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            guard voiceAttempt == attempt, draftIdentity == identity, !Task.isCancelled else { return }
            guard !transcript.isEmpty else {
                voicePhase = .idle
                store.errorMessage = speech.error ?? "没有识别到文字，请再试一次。"
                return
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.88)) {
                text = text.isEmpty ? transcript : "\(text)\n\(transcript)"
                voicePhase = .idle
                revealedVoiceText.toggle()
            }
            store.setDraft(text, for: draftKey)
            if sendAfter {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 220))
                guard voiceAttempt == attempt, draftIdentity == identity, !Task.isCancelled else { return }
                if canSend { submit() }
            }
        }
    }

    private var primaryButton: some View {
        Button {
            if isRunning, let sessionID { Task { await store.stop(sessionID) } }
            else if canSend { submit() }
        } label: {
            Group {
                if sessionID.map({ store.stoppingSessions.contains($0) }) ?? false { ProgressView().tint(.white) }
                else if isRunning { Image(systemName: "stop.fill").font(.system(size: 14)) }
                else { Image(systemName: "arrow.up").font(.system(size: 22, weight: .semibold)) }
            }
            .foregroundStyle(.white).frame(width: 34, height: 34)
            .background(!isRunning && !canSend ? Color.gray.opacity(0.28) : ZTheme.accent, in: Circle())
        }
        .disabled(isRunning ? (sessionID.map { store.stoppingSessions.contains($0) } ?? false)
                  : !canSend)
        .accessibilityLabel(isRunning ? "停止任务" : "发送消息")
        .accessibilityIdentifier("composer.send").accessibilityHidden(voiceActive)
    }

    private var attachmentMenu: some View {
        Button { focused = false; showAttachmentMenu.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 21, weight: .regular)).frame(width: 28, height: 34)
        }
        .disabled(attachmentDraftIdentity != draftIdentity)
        .tint(.primary).accessibilityLabel("添加附件或模式").accessibilityIdentifier("composer.add").accessibilityHidden(voiceActive)
        .nativeFloatingPanel(isPresented: $showAttachmentMenu, preferredWidth: 320,
                             cornerRadius: 48, placement: .sourceLeading,
                             onDismiss: performPendingAttachmentAction) { attachmentPanel }
    }

    private var attachmentPanel: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    attachmentAction(isPlanMode ? "关闭计划模式" : "计划模式", symbol: "list.bullet", enabled: store.canEditSettings(sessionID)) {
                        if isPlanMode && permission == .full && !store.isReferenceMode { confirmPlanExit = true }
                        else { setPlanMode(!isPlanMode) }
                    }
                    attachmentAction("追求目标", symbol: "scope", enabled: store.canStartGoal(sessionID)) { showGoalEditor = true }
                    attachmentAction("文件", symbol: "paperclip") { showFiles = true }
                    attachmentAction("相机", symbol: "camera") {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { store.errorMessage = "此设备没有可用相机。你可以从照片中选择图片。" }
                    }
                    attachmentAction("照片", symbol: "photo.on.rectangle") { showPhotos = true }
                    if showsReferenceDocuments {
                        Text("插件").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 28).padding(.top, 18)
                        attachmentAction("Documents", symbol: "doc.text.fill", rowHeight: 44) { showFiles = true }
                    } else if !store.canStartGoal(sessionID) {
                        Text(store.connection.isOnline ? "请在可控制的任务中设置目标。" : "连接电脑后可以设置目标。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 8)
                    }
                }.padding(.vertical, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { attachmentContentHeight = $0 }
            }.frame(height: min(attachmentContentHeight, 420.666667))
                .accessibilityIdentifier("composer.attachmentsPanel")
    }

    private func attachmentAction(_ title: String, symbol: String, enabled: Bool = true, rowHeight: CGFloat = 68,
                                  action: @escaping () -> Void) -> some View {
        Button {
            let identity = draftIdentity
            pendingAttachmentAction = {
                guard identity == draftIdentity else { return }
                action()
            }
            showAttachmentMenu = false
        } label: {
            HStack(spacing: 16) {
                Group {
                    if symbol == "scope" { TargetArrowGlyph().stroke(style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)).frame(width: 24, height: 24) }
                    else if symbol == "list.bullet" { PlanListGlyph().stroke(style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)).frame(width: 22, height: 22) }
                    else if symbol == "doc.text.fill" { DocumentReferenceIcon() }
                    else { Image(systemName: symbol).font(.system(size: 22, weight: .medium)).rotationEffect(.degrees(symbol == "paperclip" ? -45 : 0)) }
                }
                    .frame(width: 44, height: 44)
                    .background(symbol == "doc.text.fill" ? Color.clear : Color.primary.opacity(0.045), in: Circle())
                Text(title).font(.system(size: 20))
                Spacer(minLength: 0)
            }.padding(.horizontal, 28).frame(minHeight: rowHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private func performPendingAttachmentAction() {
        let action = pendingAttachmentAction
        pendingAttachmentAction = nil
        action?()
    }

    private var permissionButton: some View {
        Button { showContext = false; showPermissions.toggle() } label: {
            Image(systemName: permission.symbol)
                .font(.system(size: 19)).foregroundStyle(permission == .full ? .orange : .secondary)
                .frame(width: 34, height: 34)
        }
        .accessibilityLabel("权限，\(permission.title)").accessibilityIdentifier("composer.permissions").accessibilityHidden(voiceActive)
        .popover(isPresented: $showPermissions, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            PermissionsView(sessionID: sessionID).presentationCompactAdaptation(.popover)
        }
    }

    private var reasoningButton: some View {
        Button {
            reasoningDraft = currentReasoning
            showReasoning = true
        } label: {
            ReasoningDial(level: currentReasoning, activation: dialActivation)
                .frame(width: 32, height: 34)
        }.accessibilityLabel("模型与思考强度").accessibilityIdentifier("composer.reasoning").accessibilityHidden(voiceActive)
    }

    private var reasoningPanel: some View {
        VStack(spacing: 20) {
            Button { store.sheet = .advanced; showReasoning = false } label: {
                HStack(spacing: 7) {
                    Text(currentModelName).font(.system(size: 23, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(reasoningDraft.label).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }.font(.system(size: 21))
            }.accessibilityIdentifier("reasoning.advanced")
            ReasoningSlider(level: $reasoningDraft, levels: availableReasoning) { level in
                if store.isReferenceMode { store.options.reasoning = level }
                else {
                    let identity = draftIdentity
                    Task {
                        _ = await store.updateSettings(sessionID, reasoning: level.wireValue)
                        guard identity == draftIdentity else { return }
                        reasoningDraft = currentReasoning
                    }
                }
            }
                .frame(height: 72).padding(.horizontal, 37.333333)
                .disabled(!store.canEditSettings(sessionID, model: true))
            if !store.canEditSettings(sessionID, model: true) {
                Text("当前轮次结束后可调整模型与思考强度。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .onTapGesture(count: 2) { showReasoning = false }
        .accessibilityAction(named: "返回输入") { showReasoning = false }
    }

    private func setPlanMode(_ enabled: Bool, confirmed: Bool = false) {
        Task {
            if store.isReferenceMode { store.options.isPlanMode = enabled }
            else {
                _ = await store.updateSettings(sessionID, mode: enabled ? "plan" : permission.wireValue,
                                               confirmFullAccess: confirmed)
            }
        }
    }

    private func addAttachment(data: Data, name: String, mime: String) {
        let allowed = ["image/png", "image/jpeg", "image/webp", "image/gif", "application/pdf", "text/plain", "text/markdown", "text/csv", "application/json"]
        let resolvedMime = allowed.contains(mime) ? mime : String(data: data, encoding: .utf8) != nil ? "text/plain" : mime
        let limit = resolvedMime.hasPrefix("image/") || resolvedMime == "application/pdf" ? 8 * 1024 * 1024 : 64 * 1024
        guard attachments.count < 6 else { store.errorMessage = "每条消息最多添加 6 个附件。"; return }
        guard !data.isEmpty else { store.errorMessage = "文件为空，请选择有内容的文件。"; return }
        guard data.count <= limit else {
            store.errorMessage = limit > 100_000 ? "图片或 PDF 不能超过 8 MB。" : "文本附件不能超过 64 KB。"; return
        }
        guard allowed.contains(resolvedMime) else { store.errorMessage = "暂不支持这个文件类型。"; return }
        attachments.append(Attachment(name: name, data: data, mimeType: resolvedMime))
    }

    private var selection: ModelSelection? {
        if let sessionID { store.modelSelections[sessionID] } else { store.effectiveNewModelSelection }
    }
    private var currentModelName: String {
        if store.isReferenceMode { return store.options.model }
        guard let selection else { return "沿用电脑配置" }
        return store.models.first(where: { $0.providerId == selection.providerId && $0.modelId == selection.modelId })?.name ?? selection.modelId
    }
    private var currentReasoning: ReasoningLevel {
        store.isReferenceMode ? store.options.reasoning : selection?.thoughtLevel.flatMap(ReasoningLevel.init(wireValue:)) ?? .high
    }
    private var availableReasoning: [ReasoningLevel] {
        guard !store.isReferenceMode else { return ReasoningLevel.allCases.filter { $0 != .minimal } }
        guard let selection,
              let model = store.models.first(where: { $0.providerId == selection.providerId && $0.modelId == selection.modelId }) else { return [currentReasoning] }
        let values = model.thoughtLevels.compactMap(ReasoningLevel.init(wireValue:))
        return values.isEmpty ? [currentReasoning] : values
    }

    private func submit(retryPending: Bool = false) {
        guard !submitting, canSend || retryPending else { return }
        submitting = true
        let pending = retryPending ? store.pendingSubmissions[draftKey] : nil
        let originalText = pending?.text ?? text
        let originalAttachments = pending?.attachments ?? attachments
        let submittedKey = draftKey
        let submittedProfile = store.activeProfileID
        let submittedSession = sessionID
        Task {
            if let id = await store.submitDraft(originalText, attachments: originalAttachments,
                                                draftKey: submittedKey, sessionID: submittedSession, retryPending: retryPending,
                                                onPrepared: { id in
                guard store.activeProfileID == submittedProfile, draftKey == submittedKey else { return }
                if store.hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                text = ""
                attachments = []
                focused = false
            }) {
                guard store.activeProfileID == submittedProfile, draftKey == submittedKey else {
                    if store.activeProfileID == submittedProfile {
                        if store.drafts[submittedKey] == originalText { store.setDraft("", for: submittedKey) }
                        let sentIDs = Set(originalAttachments.map(\.id))
                        store.setDraftAttachments((store.draftAttachments[submittedKey] ?? []).filter { !sentIDs.contains($0.id) }, for: submittedKey)
                    }
                    submitting = false
                    return
                }
                if text == originalText { text = "" }
                let sentIDs = Set(originalAttachments.map(\.id))
                attachments.removeAll { sentIDs.contains($0.id) }
                store.setDraftAttachments(attachments, for: submittedKey)
                store.setDraft(text, for: submittedKey)
                focused = false
                if sessionID == nil && !store.path.contains(.session(id)) {
                    store.path.removeAll { $0 == .newSession }
                    store.path.append(.session(id))
                }
            } else if store.activeProfileID == submittedProfile, draftKey == submittedKey {
                // A transport failure restores the original draft without replacing new typing.
                if text.isEmpty { text = originalText }
                if attachments.isEmpty { attachments = originalAttachments }
                store.setDraft(text, for: submittedKey)
                store.setDraftAttachments(attachments, for: submittedKey)
            }
            submitting = false
        }
    }
}

struct ReasoningSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var level: ReasoningLevel
    var levels: [ReasoningLevel] = ReasoningLevel.allCases
    var onCommit: (ReasoningLevel) -> Void = { _ in }
    var body: some View {
        GeometryReader { geometry in
            let step = (geometry.size.width - 73.333333) / CGFloat(max(1, levels.count - 1))
            let selected = levels.firstIndex(of: level) ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(ZTheme.accent).frame(width: 48 + CGFloat(selected) * step, height: 48).padding(.leading, 12)
                HStack {
                    ForEach(levels) { item in
                        Circle().fill(item.rawValue <= level.rawValue ? .white.opacity(0.3) : .gray.opacity(0.4))
                            .frame(width: 12, height: 12)
                            .frame(width: 40)
                        if item != levels.last { Spacer(minLength: 0) }
                    }
                }.padding(.horizontal, 16.666667)
                Circle().fill(.white).frame(width: 40, height: 40)
                    .offset(x: 16.666667 + CGFloat(selected) * step)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: level)
            .sensoryFeedback(.selection, trigger: level)
            .frame(height: 72).glassEffect(ZTheme.controlGlass, in: Capsule())
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let index = min(levels.count - 1, max(0, Int(((value.location.x - 36.666667) / max(1, step)).rounded())))
                    if levels.indices.contains(index), levels[index] != level { level = levels[index] }
                }.onEnded { _ in onCommit(level) })
        }
        .accessibilityElement().accessibilityLabel("思考强度").accessibilityValue(level.label)
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 1 : -1
            let index = levels.firstIndex(of: level) ?? 0
            level = levels[min(levels.count - 1, max(0, index + delta))]
            onCommit(level)
        }
        .accessibilityIdentifier("reasoning.slider")
        .measureLayout("reasoning.slider")
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss(); parent.onFinish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85)
            parent.dismiss()
            parent.onFinish(data)
        }
    }
}

private struct ContextUsageButton: View {
    let usage: ContextUsage
    @Binding var presented: Bool
    private var percent: Double { min(100, max(0, usage.usedPercent ?? 0)) }
    private func tokens(_ value: Double) -> String {
        value >= 10_000 ? String(format: "%.1f万", value / 10_000) : value.formatted(.number.precision(.fractionLength(0)))
    }
    private var categories: [(String, Double)] {
        let labels = [("系统工具", ["system_tool_schemas"]), ("MCP 工具", ["mcp_tool_schemas"]), ("消息", ["messages"]), ("系统提示词", ["system_prompt"]), ("技能", ["skills"]), ("其他", ["meta_user_context", "tool_prompt"])]
        return labels.compactMap { label, sources in
            let rows = usage.breakdown.filter { sources.contains($0.source) }
            return rows.isEmpty ? nil : (label, rows.reduce(0) { $0 + $1.percent })
        }
    }
    var body: some View {
        Button { presented.toggle() } label: {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                if usage.available {
                    Circle().trim(from: 0, to: percent / 100)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else { Text("—").font(.system(size: 10)) }
            }.frame(width: 19, height: 19).frame(width: 32, height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(usage.available ? "上下文已用 \(percent.formatted(.number.precision(.fractionLength(1))))%" : "上下文用量暂不可用")
            .accessibilityIdentifier("composer.contextUsage")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("上下文容量").font(.headline)
                    if usage.available, let used = usage.usedTokens, let max = usage.maxTokens {
                        Text("\(tokens(used)) / \(tokens(max))（\(percent.formatted(.number.precision(.fractionLength(1))))%）")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        ProgressView(value: percent, total: 100).tint(ZTheme.accent)
                        ForEach(categories, id: \.0) { label, value in
                            HStack {
                                Circle().fill(ZTheme.accent).frame(width: 5, height: 5)
                                Text(label)
                                Spacer()
                                Text("\(value.formatted(.number.precision(.fractionLength(1))))%").monospacedDigit()
                            }.font(.subheadline)
                        }
                        if !categories.isEmpty {
                            Text("分类占比按主机的字符统计，与桌面一致。").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let threshold = usage.autoCompactThresholdTokens {
                            Text("达到 \(tokens(threshold)) tokens 时由电脑自动压缩。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("电脑尚未提供当前上下文统计。").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(18).frame(width: 290)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

private struct CompactionStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let compaction: ContextUsage.Compaction
    @State private var visibleCompletion = false
    @State private var completionRevision = 0
    var body: some View {
        Group {
            if compaction.active {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在压缩上下文…")
                }.accessibilityIdentifier("context.compacting")
            } else if visibleCompletion, let latest = compaction.latest {
                Label(latest.status == "success" ? "上下文已压缩" : latest.status == "failed" ? "上下文压缩失败" : "上下文压缩已结束", systemImage: latest.status == "success" ? "checkmark.circle" : "info.circle")
                    .accessibilityIdentifier("context.compacted")
            }
        }.font(.caption).foregroundStyle(.secondary)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: compaction.active)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: visibleCompletion)
            .onChange(of: compaction.latest) { _, latest in
                if let latest, latest.status != "running", !compaction.active {
                    visibleCompletion = true
                    completionRevision += 1
                }
            }
            .onChange(of: compaction.active) { old, new in
                if old && !new, let latest = compaction.latest, latest.status != "running" {
                    visibleCompletion = true
                    completionRevision += 1
                }
            }
            .task(id: completionRevision) {
                guard visibleCompletion else { return }
                let revision = completionRevision
                do {
                    try await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, revision == completionRevision else { return }
                    visibleCompletion = false
                } catch { }
            }
    }
}
