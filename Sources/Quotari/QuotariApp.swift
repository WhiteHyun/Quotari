import QuotariCore
import SwiftUI

@main
struct QuotariApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environment(store)
        } label: {
            // The one hand-rendered piece: a crisp CG gauge (SwiftUI can't yet
            // give a sized, gauge-style menu-bar icon). The popover is SwiftUI.
            Image(nsImage: store.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environment(store)
        }
    }
}

/// Minimal delegate: run as a menu-bar-only (accessory) app so `swift run`
/// doesn't show a Dock icon. In a bundled release this is `LSUIElement=true`
/// in Info.plist instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
