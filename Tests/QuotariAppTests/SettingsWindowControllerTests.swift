import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct SettingsWindowControllerTests {
  @Test func showsSettingsWindowWithoutAnAppBundle() {
    let store = UsageStore.isolatedForTesting(
      providers: ProviderRegistry.all,
      startsAutomatically: false
    )
    let controller = SettingsWindowController()
    defer { controller.close() }

    controller.show(store: store)

    #expect(controller.isVisible)
    #expect(controller.windowTitle == "Settings")
    #expect(controller.isResizable)
    #expect(controller.minimumContentSize == NSSize(width: 460, height: 420))
  }
}
