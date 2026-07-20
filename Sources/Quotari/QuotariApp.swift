import Combine
import Darwin
import Foundation
import MenuBarExtraAccess
import QuotariCore
import SwiftUI

@main
private enum QuotariEntrypoint {
  static func main() {
    if CommandLine.arguments.contains("--verify-packaged-resources") {
      guard IconRenderer.packagedResourcesAreReady else {
        let message = "Packaged SwiftPM resources failed validation.\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        Darwin.exit(EXIT_FAILURE)
      }
      Darwin.exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.contains("--verify-packaged-settings") {
      Darwin.exit(verifyPackagedSettings() ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    QuotariApp.main()
  }

  @MainActor
  private static func verifyPackagedSettings() -> Bool {
    _ = NSApplication.shared
    let store = UsageStore(providers: [], startsAutomatically: false)
    let hosting = NSHostingView(rootView: PreferencesView().environment(store))
    hosting.frame = NSRect(x: 0, y: 0, width: 980, height: 680)

    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    defer { window.orderOut(nil) }

    return hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0
  }
}

struct QuotariApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = UsageStore()
  @State private var menuBarPresentation = MenuBarPresentationController()

  var body: some Scene {
    MenuBarExtra {
      DashboardView(menuBarPresentation: menuBarPresentation)
        .environment(store)
        .introspectMenuBarExtraWindow { window in
          menuBarPresentation.trackDashboardWindow(window)
        }
    } label: {
      MenuBarMascotLabel(store: store)
    }
    .menuBarExtraAccess(
      isPresented: menuBarPresentationBinding,
      statusItem: { _ in
        menuBarPresentation.registerShortcutWhenStatusItemIsReady()
      }
    )
    .menuBarExtraStyle(.window)
  }

  private var menuBarPresentationBinding: Binding<Bool> {
    Binding(
      get: { menuBarPresentation.isPresented },
      set: { menuBarPresentation.isPresented = $0 }
    )
  }
}

private struct MenuBarMascotLabel: View {
  private struct AnimationConfiguration: Hashable {
    var animates: Bool
    var interval: TimeInterval
  }

  let store: UsageStore
  @State private var frameIndex = 0

  var body: some View {
    HStack(spacing: 2) {
      Image(nsImage: store.menuBarIcon(frame: frameIndex))
      if let remaining = store.menuBarRemainingText {
        Text(remaining)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .monospacedDigit()
          .frame(width: 32, alignment: .trailing)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(store.menuBarAccessibilityLabel)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      applicationDidBecomeActive()
    }
    .task(id: animationConfiguration) {
      let configuration = animationConfiguration
      guard configuration.animates, IconRenderer.frameCount > 1 else {
        frameIndex = 0
        return
      }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(configuration.interval))
        } catch {
          return
        }
        frameIndex = (frameIndex + 1) % IconRenderer.frameCount
      }
    }
  }

  private var animationConfiguration: AnimationConfiguration {
    AnimationConfiguration(
      animates: store.menuBarPreferences.preferences.animatesMascot,
      interval: store.menuBarAnimationInterval
    )
  }

  private func applicationDidBecomeActive() {
    store.beginAccountRediscovery()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
    _ = UpdaterController.shared // start background update checks when packaged
  }
}
