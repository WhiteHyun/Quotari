import Foundation
@testable import Quotari

@MainActor
extension MenuBarPreferencesController {
  static func isolatedForTesting(defaults: UserDefaults) -> MenuBarPreferencesController {
    MenuBarPreferencesController(
      defaults: defaults,
      customMascotArchiveURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("quotari-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("custom-mascot.plist")
    )
  }
}
