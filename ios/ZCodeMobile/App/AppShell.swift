import SwiftUI

struct AppShell: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            Group {
                if store.requiresInitialConnection {
                    PairingView(embedded: true, onboarding: true)
                } else {
                    HomeView()
                }
            }
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .session(let id): ChatView(sessionID: id)
                    case .newSession: NewSessionView()
                    }
                }
        }
        .sheet(item: $store.sheet) { destination in
            switch destination {
            case .connections: ConnectionsView()
            case .settings: SettingsView()
            case .pairing: PairingView()
            case .advanced: AdvancedSettingsView()
            case .files(let id, let modified): FilesView(sessionID: id, initiallyModified: modified)
            case .agent(let agent): AgentDetailView(agent: agent)
            case .voice: VoiceCaptureView()
            }
        }
        .alert("暂时无法完成", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Text(toast).font(.subheadline).padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .task { await store.start() }
        .task {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--performance-probe") else { return }
            MotionPerformanceProbe.shared.start(sessionName: "scroll-review", metadata: ["configuration": "Debug", "arguments": ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("--") }.joined(separator: " ")])
            do {
                try await Task.sleep(for: .seconds(60))
                try await MotionPerformanceProbe.shared.stopAndWrite(to: URL.documentsDirectory.appending(path: "scroll-probe.json"))
            } catch { MotionPerformanceProbe.shared.stopWithoutWriting() }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.applicationDidBecomeActive() } }
            else if phase == .background { store.applicationDidEnterBackground() }
        }
    }
}
