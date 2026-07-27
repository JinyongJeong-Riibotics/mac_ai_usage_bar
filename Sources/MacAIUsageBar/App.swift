import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        // Begin polling + token refresh at launch, not on first menu open — the
        // app may run for hours untouched (login item) and must stay refreshed.
        MainActor.assumeIsolated { UsageStore.shared.start() }
    }
}

@main
struct MacAIUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store, settings: settings)
                .onAppear { store.start() }
        } label: {
            BarLabelView(store: store, settings: settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings)
        }
    }
}
