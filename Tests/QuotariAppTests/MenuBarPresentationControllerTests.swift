import AppKit
@testable import Quotari
import Testing

@MainActor
struct MenuBarPresentationControllerTests {
  @Test func registersTheShortcutOnceAfterTheStatusItemIsReady() throws {
    var registrationCount = 0
    var action: (() -> Void)?
    let controller = MenuBarPresentationController { registeredAction in
      registrationCount += 1
      action = registeredAction
    }

    controller.registerShortcutWhenStatusItemIsReady()
    controller.registerShortcutWhenStatusItemIsReady()

    #expect(registrationCount == 1)
    let registeredAction = try #require(action)
    registeredAction()
    #expect(controller.isPresented)
  }

  @Test func shortcutActionTogglesTheDashboardPresentation() {
    let controller = MenuBarPresentationController(registersShortcut: false)

    controller.toggleDashboard()
    #expect(controller.isPresented)

    controller.toggleDashboard()
    #expect(!controller.isPresented)
  }

  @Test func dismissingDashboardClosesTheTrackedWindow() {
    let controller = MenuBarPresentationController(registersShortcut: false)
    let window = CloseTrackingWindow()
    controller.isPresented = true
    controller.trackDashboardWindow(window)

    controller.dismissDashboard()

    #expect(!controller.isPresented)
    #expect(window.didClose)
  }

  @Test func fittingTheDashboardWindowShrinksItBelowTheMenuBar() {
    let controller = MenuBarPresentationController(registersShortcut: false)
    let window = dashboardWindow(height: 560)
    controller.trackDashboardWindow(window)

    controller.fitDashboardWindow(toHeight: 382)

    #expect(window.frame == NSRect(x: 1021, y: 565, width: 300, height: 382))
  }

  @Test func fittingTheDashboardWindowGrowsItBelowTheMenuBar() {
    let controller = MenuBarPresentationController(registersShortcut: false)
    let window = dashboardWindow(height: 200)
    controller.trackDashboardWindow(window)

    controller.fitDashboardWindow(toHeight: 500)

    #expect(window.frame == NSRect(x: 1021, y: 447, width: 300, height: 500))
  }

  @Test func heightMeasuredBeforeTheWindowIsTrackedIsAppliedOnTracking() {
    let controller = MenuBarPresentationController(registersShortcut: false)
    let window = dashboardWindow(height: 560)

    controller.fitDashboardWindow(toHeight: 382)
    controller.trackDashboardWindow(window)

    #expect(window.frame == NSRect(x: 1021, y: 565, width: 300, height: 382))
  }

  private func dashboardWindow(height: CGFloat) -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 1021, y: 947 - height, width: 300, height: height),
      styleMask: .borderless,
      backing: .buffered,
      defer: true
    )
  }
}

private final class CloseTrackingWindow: NSWindow {
  private(set) var didClose = false

  override func close() {
    didClose = true
  }
}
