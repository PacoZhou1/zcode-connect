import SwiftUI
import UIKit
import UserNotifications

@main
struct ZCodeMobileApp: App {
    @State private var store: AppStore
    private static func makeStore() -> AppStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--onboarding-review"),
           let defaults = UserDefaults(suiteName: "dev.paco.zcode.mobile.onboarding-review") {
            return AppStore(defaults: defaults)
        }
        #endif
        return AppStore()
    }
    init() {
        _store = State(initialValue: Self.makeStore())
        TaskNotifications.shared.store = _store.wrappedValue
    }
    var body: some Scene {
        WindowGroup {
            rootView
                .environment(store)
                .tint(ZTheme.accent)
                .preferredColorScheme(store.appearance == "浅色" ? .light : store.appearance == "深色" ? .dark : nil)
        }
    }
    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("material-calibration") { GlassCalibrationView() }
        else { AppShell() }
        #else
        AppShell()
        #endif
    }
}

/// System notifications for finished tasks. All UserNotifications/UIKit work
/// stays in the app layer so the extracted Core test harnesses never touch it.
/// State is only touched on the main actor; the class is a process-wide singleton.
@MainActor
final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = TaskNotifications()
    weak var store: AppStore?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func postCompletion(sessionID: String, title: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              settings.alertSetting == .enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "任务" : title
        content.body = "电脑上的任务已完成。"
        content.sound = .default
        content.userInfo = ["sessionID": sessionID]
        let request = UNNotificationRequest(identifier: "task-complete-" + sessionID + "-" + UUID().uuidString,
                                            content: content, trigger: nil)
        try? await center.add(request)
    }

    /// A just-backgrounded app keeps its attached transport briefly, so an imminent
    /// completion can still surface as a notification instead of a silent end.
    func beginBackgroundWindowIfRunning() {
        guard backgroundTaskID == .invalid,
              store?.sessions.contains(where: { [.running, .waiting].contains($0.status) }) == true else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "task-completion-watch") { [weak self] in
            self?.endBackgroundWindow()
        }
    }

    func endBackgroundWindow() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// The system hands over non-Sendable completion handlers; each is called
    /// exactly once from the main actor, so boxing is sound.
    private struct HandlerBox<Value>: @unchecked Sendable { let value: Value }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        let handler = HandlerBox(value: completionHandler)
        Task { @MainActor [weak self] in
            if let sessionID { self?.store?.openFromNotification(sessionID) }
            handler.value()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let sessionID = notification.request.content.userInfo["sessionID"] as? String
        let handler = HandlerBox(value: completionHandler)
        Task { @MainActor [weak self] in
            // Watching the finished task itself already shows the result and haptic.
            handler.value(self?.store?.currentSessionID == sessionID ? [] : [.banner, .sound])
        }
    }
}
