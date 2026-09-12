import SwiftUI

struct VoiceCaptureView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var finishing = false
    @State private var attempt = UUID()
    @State private var capture = SpeechCapture()
    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                Spacer(minLength: 10)
                Group {
                    if capture.isRecording { LiveVoiceWaveform(capture: capture).frame(width: 240, height: 60) }
                    else { Image(systemName: "mic").font(.system(size: 60, weight: .light)).foregroundStyle(ZTheme.accent) }
                }.frame(height: 60)
                Text(capture.isRecording ? "正在听…" : "说出你的任务").font(.title2.weight(.semibold))
                Text("识别后可编辑文字，再发送到电脑。").font(.subheadline).foregroundStyle(.secondary)
                if let error = capture.error { Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center) }
                TextEditor(text: $capture.text)
                    .scrollContentBackground(.hidden).padding(12)
                    .frame(minHeight: 100, maxHeight: 220)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityIdentifier("voice.transcript")
                HStack(spacing: 20) {
                    Button(capture.isStarting ? "正在准备…" : capture.isRecording ? "停止录音" : "开始录音") {
                        if capture.isRecording {
                            finishing = true
                            Task { _ = await capture.finish(); finishing = false }
                        } else { Task { await capture.start() } }
                    }.buttonStyle(NativeGlassButtonStyle()).controlSize(.large).disabled(capture.isStarting || finishing)
                    Button("使用文字") {
                        finishing = true
                        let currentAttempt = attempt
                        let sessionID = store.currentSessionID
                        let key = sessionID ?? "new:\(store.selectedProjectID ?? "")"
                        let profileID = store.activeProfileID
                        Task {
                        _ = await capture.finish()
                        guard currentAttempt == attempt, profileID == store.activeProfileID,
                              sessionID == store.currentSessionID,
                              key == (store.currentSessionID ?? "new:\(store.selectedProjectID ?? "")") else { return }
                        finishing = false
                        let draft = store.drafts[key] ?? ""
                        store.setDraft(draft.isEmpty ? capture.text : "\(draft)\n\(capture.text)", for: key)
                        if sessionID == nil && !store.path.contains(.newSession) { store.path.append(.newSession) }
                        dismiss()
                        }
                    }.buttonStyle(.glassProminent).controlSize(.large)
                        .disabled(finishing || capture.isStarting || capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
            }.padding(24)
                .navigationTitle("语音输入").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { capture.stop(); dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .onDisappear { attempt = UUID(); capture.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { attempt = UUID(); finishing = false; capture.stop() } }
    }
}
