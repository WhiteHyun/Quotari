import AppKit
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
  static let toggleDashboard = Self("toggleDashboard")
}

@MainActor
@Observable
final class MenuBarPresentationController {
  typealias ShortcutRegistrar = (@escaping () -> Void) -> Void

  var isPresented = false

  @ObservationIgnored private let shortcutRegistrar: ShortcutRegistrar?
  @ObservationIgnored private var didRegisterShortcut = false
  @ObservationIgnored private weak var dashboardWindow: NSWindow?

  init(registersShortcut: Bool = true) {
    shortcutRegistrar = registersShortcut
      ? { action in KeyboardShortcuts.onKeyUp(for: .toggleDashboard, action: action) }
      : nil
  }

  init(shortcutRegistrar: @escaping ShortcutRegistrar) {
    self.shortcutRegistrar = shortcutRegistrar
  }

  func registerShortcutWhenStatusItemIsReady() {
    guard !didRegisterShortcut, let shortcutRegistrar else { return }
    didRegisterShortcut = true
    shortcutRegistrar { [weak self] in
      self?.toggleDashboard()
    }
  }

  func toggleDashboard() {
    isPresented.toggle()
  }

  func trackDashboardWindow(_ window: NSWindow) {
    dashboardWindow = window
  }

  func dismissDashboard() {
    isPresented = false
    dashboardWindow?.close()
  }
}
