import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ProviderActivationControllerTests {
  @Test func defaultsEveryProviderToEnabled() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let controller = ProviderActivationController(defaults: defaults)

    #expect(controller.preferences.disabledProviders.isEmpty)
    for provider in UsageProvider.allCases {
      #expect(controller.isEnabled(provider))
    }
  }

  @Test func disabledProvidersPersistAcrossRelaunch() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let controller = ProviderActivationController(defaults: defaults)

    #expect(controller.setProvider(.codex, enabled: false))

    let relaunched = ProviderActivationController(defaults: defaults)
    #expect(relaunched.preferences.disabledProviders == [.codex])
    #expect(!relaunched.isEnabled(.codex))
    #expect(relaunched.isEnabled(.claude))
  }

  @Test func settingTheCurrentStateIsIdempotent() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let controller = ProviderActivationController(defaults: defaults)

    #expect(!controller.setProvider(.claude, enabled: true))
    #expect(controller.setProvider(.claude, enabled: false))
    #expect(!controller.setProvider(.claude, enabled: false))
    #expect(controller.setProvider(.claude, enabled: true))
    #expect(!controller.setProvider(.claude, enabled: true))
    #expect(controller.preferences.disabledProviders.isEmpty)
  }

  @Test func corruptedDataFallsBackToDefaultsAndRepairsPersistence() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not valid JSON".utf8), forKey: ProviderActivationController.defaultsKey)

    let controller = ProviderActivationController(defaults: defaults)

    #expect(controller.preferences == ProviderActivationPreferences())
    let repairedData = try #require(
      defaults.data(forKey: ProviderActivationController.defaultsKey)
    )
    let repaired = try JSONDecoder().decode(ProviderActivationPreferences.self, from: repairedData)
    #expect(repaired == ProviderActivationPreferences())
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let suiteName = "ProviderActivationControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (defaults, suiteName)
  }
}
