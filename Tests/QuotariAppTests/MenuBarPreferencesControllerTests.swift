import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct MenuBarPreferencesControllerTests {
  @Test func defaultsToACompactAnimatedMostConstrainedDisplay() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let controller = MenuBarPreferencesController(defaults: defaults)

    #expect(!controller.preferences.showsRemainingPercent)
    #expect(controller.preferences.usageSource == .mostConstrained)
    #expect(controller.preferences.animatesMascot)
  }

  @Test func mutationsPersistAcrossRelaunch() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let controller = MenuBarPreferencesController(defaults: defaults)

    controller.setShowsRemainingPercent(true)
    controller.setUsageSource(.provider(.claude))
    controller.setAnimatesMascot(false)

    let relaunched = MenuBarPreferencesController(defaults: defaults)
    #expect(
      relaunched.preferences == MenuBarPreferences(
        showsRemainingPercent: true,
        usageSource: .provider(.claude),
        animatesMascot: false
      )
    )
  }

  @Test func corruptedDataFallsBackToDefaultsAndRepairsPersistence() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not valid JSON".utf8), forKey: MenuBarPreferencesController.defaultsKey)

    let controller = MenuBarPreferencesController(defaults: defaults)

    #expect(controller.preferences == MenuBarPreferences())
    let repairedData = try #require(
      defaults.data(forKey: MenuBarPreferencesController.defaultsKey)
    )
    let repaired = try JSONDecoder().decode(MenuBarPreferences.self, from: repairedData)
    #expect(repaired == MenuBarPreferences())
  }

  @Test func settablePropertiesRouteThroughPersistence() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let controller = MenuBarPreferencesController(defaults: defaults)

    controller.showsRemainingPercent = true
    controller.usageSource = .provider(.codex)
    controller.animatesMascot = false

    let relaunched = MenuBarPreferencesController(defaults: defaults)
    #expect(relaunched.showsRemainingPercent)
    #expect(relaunched.usageSource == .provider(.codex))
    #expect(!relaunched.animatesMascot)
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let suiteName = "MenuBarPreferencesControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (defaults, suiteName)
  }
}
