import Foundation
import Observation
import AVFoundation
@preconcurrency import Speech

@MainActor @Observable
final class SpeechCapture {
    var text = ""
    var isRecording = false
    var isStarting = false
    var levels: [Float] = []
    var error: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var hasTap = false
    @ObservationIgnored private var generation = UUID()

    func start() async {
        stop()
        let generation = self.generation
        isStarting = true
        defer { if generation == self.generation { isStarting = false } }
        error = nil
        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        guard speechPermission == .authorized else {
            error = "请在系统设置中允许 ZCode 使用语音识别。"; return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard generation == self.generation, !Task.isCancelled else { return }
        guard microphone else { error = "请在系统设置中允许 ZCode 使用麦克风。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            error = "语音识别暂不可用，请稍后重试。"; return
        }
        text = ""
        levels = []
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                error = "当前设备没有可用的音频输入。"; stop(); return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let level = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 45))
                Task { @MainActor [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.levels.append(level)
                    if self.levels.count > 100 { self.levels.removeFirst(self.levels.count - 100) }
                }
            }
            hasTap = true
            engine.prepare()
            try engine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                let transcript = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let errorText = failure?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, generation == self.generation else { return }
                    if let transcript { self.text = transcript }
                    if final || errorText != nil {
                        if self.text.isEmpty, let errorText { self.error = errorText }
                        self.stop()
                    }
                }
            }
        } catch { self.error = error.localizedDescription; stop() }
    }
    /// Ends audio while allowing the recognizer to deliver its final transcription.
    func finish() async -> String {
        guard isRecording || isStarting else { return text }
        let finishingGeneration = generation
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        task?.finish()
        for _ in 0..<60 {
            if generation != finishingGeneration || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let result = text
        if generation == finishingGeneration { stop() }
        return result
    }

    func stop() {
        generation = UUID()
        isStarting = false
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
