import MenuBarExtraAccess
import QuotariCore
import SwiftUI

@main
struct QuotariApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = UsageStore()
  @State private var menuBarPresentation = MenuBarPresentationController()

  var body: some Scene {
    MenuBarExtra {
      DashboardView()
        .environment(store)
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
    _ = UpdaterController.shared // start background update checks when packaged
  }
}
