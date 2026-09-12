import SwiftUI

enum InlineVoicePhase: Equatable {
    case idle, preparing, recording, transcribing
}

struct InlineVoiceControls: View {
    let capture: SpeechCapture
    let phase: InlineVoicePhase
    var cancel: () -> Void
    var finish: () -> Void
    var send: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                    .frame(width: 32, height: 32).background(.primary.opacity(0.035), in: Circle())
            }.accessibilityLabel("取消语音输入").accessibilityIdentifier("voice.inline.cancel")
            Group {
                if phase == .recording {
                    LiveVoiceWaveform(capture: capture)
                } else {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(phase == .preparing ? "正在准备…" : "正在转录")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 30)
            Button(action: finish) {
                Image(systemName: "stop.fill").font(.system(size: 12))
                    .frame(width: 32, height: 32).background(.primary.opacity(0.035), in: Circle())
            }.disabled(phase != .recording)
                .accessibilityLabel("停止录音并编辑文字").accessibilityIdentifier("voice.inline.finish")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 32, height: 32)
                    .background(phase == .recording ? ZTheme.accent : .gray.opacity(0.4), in: Circle())
            }.disabled(phase != .recording)
                .accessibilityLabel("转录并发送").accessibilityIdentifier("voice.inline.send")
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .padding(.horizontal, 6).frame(height: 48)
    }
}

/// Only this small view observes audio samples; no animation timer invalidates the conversation.
struct LiveVoiceWaveform: View {
    let capture: SpeechCapture
    var body: some View {
        let levels = capture.levels
        Canvas { context, size in
            let pitch: CGFloat = 3
            let capacity = max(1, Int(size.width / pitch))
            let samples = Array(levels.suffix(capacity))
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(baseline, with: .color(.secondary.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
            var bars = Path()
            for (index, sample) in samples.enumerated() {
                let x = size.width - CGFloat(samples.count - index) * pitch
                let height = max(1.3, CGFloat(sample) * (size.height - 3))
                bars.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                bars.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
            }
            context.stroke(bars, with: .color(.primary.opacity(0.72)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .accessibilityLabel("录音音量波形")
        .accessibilityValue(capture.isRecording ? "正在录音" : "录音已停止")
    }
}
