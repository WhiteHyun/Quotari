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
}

private final class CloseTrackingWindow: NSWindow {
  private(set) var didClose = false

  override func close() {
    didClose = true
  }
}
