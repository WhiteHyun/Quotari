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
      Image(nsImage: store.menuBarIcon)
        .accessibilityLabel(store.menuBarAccessibilityLabel)
    }
    .menuBarExtraStyle(.window)

    Settings {
      PreferencesView()
        .environment(store)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
  }
}
