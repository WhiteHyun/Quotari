import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
  static let shared = SettingsWindowController()

  private var window: NSWindow?

  var isVisible: Bool {
    window?.isVisible == true
  }

  var windowTitle: String? {
    window?.title
  }

  func show(store: UsageStore) {
    let settingsWindow = window ?? makeWindow(store: store)
    NSApplication.shared.activate(ignoringOtherApps: true)
    settingsWindow.makeKeyAndOrderFront(nil)
  }

  func close() {
    window?.close()
  }

  private func makeWindow(store: UsageStore) -> NSWindow {
    let controller = NSHostingController(
      rootView: PreferencesView()
        .environment(store)
    )
    let settingsWindow = NSWindow(contentViewController: controller)
    settingsWindow.title = "Settings"
    settingsWindow.identifier = NSUserInterfaceItemIdentifier("Quotari.Settings")
    settingsWindow.styleMask = [.titled, .closable]
    settingsWindow.isReleasedWhenClosed = false
    settingsWindow.center()
    window = settingsWindow
    return settingsWindow
  }
}
