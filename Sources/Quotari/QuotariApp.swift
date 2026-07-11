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
      MenuBarMascotLabel(store: store)
    }
    .menuBarExtraStyle(.window)

    Settings {
      PreferencesView()
        .environment(store)
    }
  }
}

private struct MenuBarMascotLabel: View {
  let store: UsageStore
  @State private var frameIndex = 0

  var body: some View {
    Image(nsImage: store.menuBarIcon(frame: frameIndex))
      .accessibilityLabel(store.menuBarAccessibilityLabel)
      .task(id: store.menuBarAnimationInterval) {
        let interval = store.menuBarAnimationInterval
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(interval))
          } catch {
            return
          }
          frameIndex = (frameIndex + 1) % IconRenderer.frameCount
        }
      }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
    _ = UpdaterController.shared // start background update checks when packaged
  }
}
