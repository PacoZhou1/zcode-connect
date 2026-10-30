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
        // Value-less guide links otherwise survive the onboarding root changing
        // to HomeView after the first successful connection.
        .id(store.requiresInitialConnection)
        .modifier(FloatingPanelOverlay())
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
        .alert(L10n.tr("暂时无法完成"), isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(L10n.tr("好"), role: .cancel) { store.errorMessage = nil }
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
        .task {
            store.completionEventSink = { sessionID, title in
                Task { await TaskNotifications.shared.postCompletion(sessionID: sessionID, title: title) }
            }
            await store.start()
            #if DEBUG
            // Deterministic, scoped owner verification on a dedicated QA device.
            // This opens the same official flow as the visible sign-in buttons; no test credential is injected.
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--official-login"),
               ProcessInfo.processInfo.arguments.count > index + 1,
               let provider = RelayAccountProvider(rawValue: ProcessInfo.processInfo.arguments[index + 1]),
               store.officialAccount.identity == nil {
                if !store.requiresInitialConnection { store.sheet = .pairing }
                store.officialAccount.signIn(provider)
            }
            #endif
        }
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
            if phase == .active {
                LanguageSettings.shared.refreshSystemLanguages()
                TaskNotifications.shared.endBackgroundWindow()
                if store.completionNotifications, store.hasConnectedBefore {
                    Task { await TaskNotifications.shared.requestAuthorizationIfNeeded() }
                }
                Task { await store.applicationDidBecomeActive() }
            } else if phase == .background {
                store.applicationDidEnterBackground()
                TaskNotifications.shared.beginBackgroundWindowIfRunning()
            }
        }
    }
}
