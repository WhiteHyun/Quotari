import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct MenuBarPreferencesControllerTests {
  @Test func defaultsToACompactAnimatedMostConstrainedDisplay() throws {
    let context = try makeContext()
    defer { context.remove() }

    let controller = context.makeController()

    #expect(!controller.preferences.showsRemainingPercent)
    #expect(controller.preferences.usageSource == .mostConstrained)
    #expect(controller.preferences.animatesMascot)
    #expect(controller.preferences.mascot == .builtIn)
  }

  @Test func mutationsPersistAcrossRelaunch() throws {
    let context = try makeContext()
    defer { context.remove() }
    let controller = context.makeController()

    controller.setShowsRemainingPercent(true)
    controller.setUsageSource(.provider(.claude))
    controller.setAnimatesMascot(false)

    let relaunched = context.makeController()
    #expect(
      relaunched.preferences == MenuBarPreferences(
        showsRemainingPercent: true,
        usageSource: .provider(.claude),
        animatesMascot: false
      )
    )
  }

  @Test func preferencesSavedBeforeMascotSelectionDefaultToBuiltIn() throws {
    let legacyData = try JSONSerialization.data(withJSONObject: [
      "showsRemainingPercent": true,
      "usageSource": ["mostConstrained": [:]],
      "animatesMascot": true,
    ])

    let preferences = try JSONDecoder().decode(MenuBarPreferences.self, from: legacyData)

    #expect(preferences.mascot == .builtIn)
  }

  @Test func corruptedDataFallsBackToDefaultsAndRepairsPersistence() throws {
    let context = try makeContext()
    defer { context.remove() }
    context.defaults.set(Data("not valid JSON".utf8), forKey: MenuBarPreferencesController.defaultsKey)

    let controller = context.makeController()

    #expect(controller.preferences == MenuBarPreferences())
    let repairedData = try #require(
      context.defaults.data(forKey: MenuBarPreferencesController.defaultsKey)
    )
    let repaired = try JSONDecoder().decode(MenuBarPreferences.self, from: repairedData)
    #expect(repaired == MenuBarPreferences())
  }

  @Test func settablePropertiesRouteThroughPersistence() throws {
    let context = try makeContext()
    defer { context.remove() }
    let controller = context.makeController()

    controller.showsRemainingPercent = true
    controller.usageSource = .provider(.codex)
    controller.animatesMascot = false

    let relaunched = context.makeController()
    #expect(relaunched.showsRemainingPercent)
    #expect(relaunched.usageSource == .provider(.codex))
    #expect(!relaunched.animatesMascot)
  }

  private struct TestContext {
    var defaults: UserDefaults
    var suiteName: String
    var directory: URL

    var archiveURL: URL {
      directory.appendingPathComponent("custom-mascot.plist")
    }

    @MainActor func makeController() -> MenuBarPreferencesController {
      MenuBarPreferencesController(
        defaults: defaults,
        customMascotArchiveURL: archiveURL
      )
    }

    func remove() {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func makeContext() throws -> TestContext {
    let suiteName = "MenuBarPreferencesControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    return TestContext(defaults: defaults, suiteName: suiteName, directory: directory)
  }
}
