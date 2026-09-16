import SwiftUI
import AVFoundation

/// Simulator mirroring UI: switch, quality settings and the live canvas with
/// touch mapping. Visual language follows the app's glass panels.
struct MirrorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var endpointDraft = ""
    @State private var tokenDraft = ""
    @State private var showFullscreen = false
    private var session: MirrorSession { MirrorSession.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("实时画面") {
                    if session.isStreaming {
                        MirrorCanvas(showsChrome: false, surface: .inline)
                            .aspectRatio(session.renderer.videoSize == .zero
                                ? CGSize(width: 886, height: 1920)
                                : session.renderer.videoSize, contentMode: .fit)
                            .frame(maxHeight: 430)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityIdentifier("mirror.canvas")
                        HStack {
                            Label(sessionPhaseText, systemImage: session.isStreaming ? "dot.radiowave.left" : "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(session.isStreaming ? Color.green : Color.red)
                            Spacer()
                            Text("\(Int(session.fps)) fps · \(Int(session.kbps)) kbps")
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Button {
                            session.renderer.surface = .fullscreen
                            showFullscreen = true
                        } label: {
                            Label("全屏操控", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .disabled(session.renderer.isPiPActive)
                        .accessibilityIdentifier("mirror.fullscreen")
                        Button {
                            // Leave the canvas first so the PiP system takes over
                            // a layer nobody else is presenting.
                            dismiss()
                            Task { try? await Task.sleep(for: .seconds(0.6)); session.renderer.startPiP() }
                        } label: {
                            Label("画中画悬浮", systemImage: "rectangle.on.rectangle")
                        }.accessibilityIdentifier("mirror.pip")
                    }
                    Button(session.isStreaming ? "停止镜像" : "开始镜像") {
                        if session.isStreaming { session.stop() }
                        else { session.updateCredentials(endpoint: endpointDraft, token: tokenDraft); session.start(windowID: session.selectedWindowID) }
                    }
                    .disabled(!session.isStreaming && (endpointDraft.isEmpty || tokenDraft.isEmpty))
                    .accessibilityIdentifier("mirror.toggle")
                }
                Section("画质") {
                    Picker("档位", selection: qualityBinding) {
                        ForEach(Array(MirrorSession.Quality.tiers.keys.sorted()), id: \.self) { key in
                            Text(key).tag(key)
                        }
                        Text("自定义").tag("自定义")
                    }
                    .accessibilityIdentifier("mirror.quality")
                    Picker("帧率", selection: fpsBinding) {
                        Text("20 fps").tag(20)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Picker("码率", selection: bitrateBinding) {
                        Text("0.6 Mbps").tag(600_000)
                        Text("1.2 Mbps").tag(1_200_000)
                        Text("2.4 Mbps").tag(2_400_000)
                        Text("4 Mbps").tag(4_000_000)
                    }
                }
                Section("连接") {
                    TextField("镜像地址（如 example.com:8443/zcode-mirror）", text: $endpointDraft)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("mirror.endpoint")
                    SecureField("镜像令牌", text: $tokenDraft)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mirror.token")
                    if session.isStreaming {
                        Picker("模拟器", selection: windowBinding) {
                            ForEach(session.windows) { window in
                                Text(window.title).tag(window.id as UInt32?)
                            }
                        }
                        .accessibilityIdentifier("mirror.windowPicker")
                        Button("刷新模拟器列表") { session.refreshWindows() }
                            .disabled(!session.isStreaming)
                    } else {
                        Text("在 Mac 上运行 mirror/MirrorAgent 后填入地址与令牌。点击会映射到模拟器窗口。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("说明") {
                    Text("镜像采集 Mac 上模拟器窗口的屏幕内容；点按、拖动会以合成交互送到模拟器。停止镜像即断开画面。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("模拟器镜像").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .fullScreenCover(isPresented: $showFullscreen) {
                MirrorFullscreen()
            }
        }
            .onChange(of: session.renderer.isPiPActive) { _, active in
                if active, !showFullscreen { dismiss() }
            }
            .onChange(of: showFullscreen) { _, presenting in
                if !presenting, session.renderer.surface == .fullscreen { session.renderer.surface = .inline }
            }
        .onAppear {
            endpointDraft = session.savedEndpoint
            if tokenDraft.isEmpty && session.savedTokenSet { tokenDraft = MirrorTokenVault.storedToken ?? "" }
            if session.savedEndpoint.isEmpty, let host = store.activeProfile?.baseURL, let url = URL(string: host) {
                endpointDraft = "\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")/zcode-mirror"
            }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--mirror-endpoint"), arguments.indices.contains(index + 1) {
                endpointDraft = arguments[index + 1]
            }
            if let index = arguments.firstIndex(of: "--mirror-token"), arguments.indices.contains(index + 1) {
                tokenDraft = arguments[index + 1]
            }
            if arguments.contains("--mirror-auto"), !session.isStreaming {
                session.updateCredentials(endpoint: endpointDraft, token: tokenDraft)
                session.start(windowID: session.selectedWindowID)
            }
            if arguments.contains("--mirror-fullscreen") {
                session.renderer.surface = .fullscreen
                showFullscreen = true
            }
            #endif
        }
    }

    private var sessionPhaseText: String {
        switch session.phase {
        case .idle: "未连接"
        case .connecting: "连接中…"
        case .streaming: session.streamingTitle ?? "正在镜像"
        case .failed(let message): message
        }
    }

    private var qualityBinding: Binding<String> {
        Binding(
            get: { session.quality.label },
            set: { key in
                if let tier = MirrorSession.Quality.tiers[key] {
                    session.quality = tier
                    if session.isStreaming { session.start(windowID: session.selectedWindowID) }
                }
            })
    }
    private var fpsBinding: Binding<Int> {
        Binding(
            get: { session.quality.fps },
            set: { fps in
                session.quality.fps = fps
                if session.isStreaming { session.start(windowID: session.selectedWindowID) }
            })
    }
    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { session.quality.bitrate },
            set: { bitrate in
                session.quality.bitrate = bitrate
                if session.isStreaming { session.start(windowID: session.selectedWindowID) }
            })
    }
    private var windowBinding: Binding<UInt32?> {
        Binding(
            get: { session.selectedWindowID },
            set: { id in
                session.selectedWindowID = id
                if session.isStreaming { session.start(windowID: id) }
            })
    }
}

/// The video surface plus mapped touch gestures.
struct MirrorCanvas: View {
    var showsChrome: Bool
    var surface: MirrorSurface = .inline
    @State private var lastDragEnd = Date.distantPast
    private var session: MirrorSession { MirrorSession.shared }

    var body: some View {
        MirrorVideoView(renderer: session.renderer, surface: surface)
            .onAppear { if session.renderer.surface == .none { session.renderer.surface = .inline } }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
            .overlay(
                RoundedRectangle(cornerRadius: showsChrome ? 0 : 1, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard let normalized = normalized(value.location) else { return }
                session.tap(normalizedX: normalized.x, y: normalized.y)
            })
            .gesture(DragGesture(minimumDistance: 10)
                .onEnded { value in
                    guard let start = normalized(value.startLocation), let end = normalized(value.location) else { return }
                    session.swipe(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y)
                })
            .overlay {
                if session.renderer.isPiPActive {
                    // The layer belongs to the floating PiP window right now.
                    Label("画面正在画中画浮窗播放", systemImage: "rectangle.on.rectangle")
                        .font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .glassEffect(.regular, in: Capsule())
                }
            }
            .allowsHitTesting(!session.renderer.isPiPActive)
    }
    @State private var canvasSize: CGSize = .zero

    /// Maps a canvas point into the video's normalized coordinates, compensating
    /// for the aspect-fit letterbox so taps land where the user sees them.
    private func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
        let video = session.renderer.videoSize
        guard canvasSize.width > 0, canvasSize.height > 0, video.width > 0, video.height > 0 else { return nil }
        let scale = min(canvasSize.width / video.width, canvasSize.height / video.height)
        let visible = CGSize(width: video.width * scale, height: video.height * scale)
        let origin = CGPoint(x: (canvasSize.width - visible.width) / 2, y: (canvasSize.height - visible.height) / 2)
        let x = (point.x - origin.x) / visible.width
        let y = (point.y - origin.y) / visible.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }
}

struct MirrorVideoView: UIViewRepresentable {
    let renderer: MirrorRenderer
    var surface: MirrorSurface = .inline

    final class HostView: UIView {
        var renderer: MirrorRenderer?
        var surface: MirrorSurface = .inline
        override func layoutSubviews() {
            super.layoutSubviews()
            renderer?.mount(in: self, surface: surface)
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.renderer = renderer
        view.surface = surface
        renderer.mount(in: view, surface: surface)
        NSLog("mirror: video host created surface=\(surface == .fullscreen ? "fullscreen" : "inline") bounds=\(view.bounds)")
        return view
    }
    func updateUIView(_ view: HostView, context: Context) {
        view.renderer = renderer
        view.surface = surface
        renderer.mount(in: view, surface: surface)
    }
}

struct MirrorFullscreen: View {
    @Environment(\.dismiss) private var dismiss
    private var session: MirrorSession { MirrorSession.shared }

    var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                MirrorCanvas(showsChrome: false, surface: .fullscreen)
                    .ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular, in: Circle())
                    .accessibilityLabel("退出全屏").accessibilityIdentifier("mirror.exitFullscreen")
                    Spacer()
                    Text("\(Int(session.fps)) fps · \(Int(session.kbps)) kbps")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                    Spacer()
                    Button {
                        dismiss()
                        Task { try? await Task.sleep(for: .seconds(0.6)); session.renderer.startPiP() }
                    } label: {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular, in: Circle())
                    .accessibilityLabel("画中画悬浮").accessibilityIdentifier("mirror.pip.fullscreen")
                    Button { session.stop(); dismiss() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.tint(.red.opacity(0.6)), in: Circle())
                    .accessibilityLabel("停止镜像").accessibilityIdentifier("mirror.stop")
                }.padding(.horizontal, 12).padding(.top, 8)
                Spacer()
            }
        }
    }
}

/// The mirror token is not part of the general keychain payloads; keep it beside
/// the mirror settings so reinstalling the app keeps the pairing intact.
enum MirrorTokenVault {
    static var storedToken: String? {
        UserDefaults.standard.string(forKey: "mirrorToken")
    }
}
