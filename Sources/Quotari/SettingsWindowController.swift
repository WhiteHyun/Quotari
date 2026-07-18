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

  var isResizable: Bool {
    window?.styleMask.contains(.resizable) == true
  }

  var minimumContentSize: NSSize? {
    window?.contentMinSize
  }

  func show(store: UsageStore) {
    store.beginAccountRediscovery()
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
    settingsWindow.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    settingsWindow.titleVisibility = .hidden
    settingsWindow.titlebarAppearsTransparent = true
    settingsWindow.isMovableByWindowBackground = true
    settingsWindow.contentMinSize = NSSize(width: 840, height: 560)
    settingsWindow.setContentSize(NSSize(width: 980, height: 680))
    settingsWindow.isReleasedWhenClosed = false
    settingsWindow.center()
    window = settingsWindow
    return settingsWindow
  }
}
