import SwiftUI

@main
struct ZCodeMobileApp: App {
    @State private var store = makeStore()
    private static func makeStore() -> AppStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--onboarding-review"),
           let defaults = UserDefaults(suiteName: "dev.paco.zcode.mobile.onboarding-review") {
            return AppStore(defaults: defaults)
        }
        #endif
        return AppStore()
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
