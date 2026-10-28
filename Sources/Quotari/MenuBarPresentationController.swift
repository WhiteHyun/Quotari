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
  @ObservationIgnored private var dashboardHeight: CGFloat?

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
    applyDashboardHeight()
  }

  /// The menu bar panel only raises its minimum size as the dashboard grows and
  /// never shrinks its frame, so once content reaches the height cap the window
  /// keeps that height and centers shorter content in transparent space. Pin the
  /// frame to the dashboard's height, keeping the top edge under the menu bar.
  func fitDashboardWindow(toHeight height: CGFloat) {
    dashboardHeight = height
    applyDashboardHeight()
  }

  private func applyDashboardHeight() {
    guard let window = dashboardWindow, let dashboardHeight else { return }
    let contentRect = window.contentRect(forFrameRect: window.frame)
    guard contentRect.height != dashboardHeight else { return }
    let fittedContentRect = NSRect(
      x: contentRect.minX,
      y: contentRect.maxY - dashboardHeight,
      width: contentRect.width,
      height: dashboardHeight
    )
    window.setFrame(window.frameRect(forContentRect: fittedContentRect), display: true)
  }

  func dismissDashboard() {
    isPresented = false
    dashboardWindow?.close()
  }
}
