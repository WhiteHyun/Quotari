import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct SettingsWindowControllerTests {
  @Test func showsSettingsWindowWithoutAnAppBundle() {
    let selectionURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-settings-\(UUID().uuidString).json")
    let store = UsageStore(
      accountSelectionStore: ProviderAccountSelectionStore(url: selectionURL),
      startsAutomatically: false
    )
    let controller = SettingsWindowController()
    defer {
      controller.close()
      try? FileManager.default.removeItem(at: selectionURL)
    }

    controller.show(store: store)

    #expect(controller.isVisible)
    #expect(controller.windowTitle == "Settings")
  }
}
