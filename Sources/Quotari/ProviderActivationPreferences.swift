import Foundation
import Observation
import QuotariCore

struct ProviderActivationPreferences: Codable, Equatable, Sendable {
  var disabledProviders: Set<UsageProvider>

  init(disabledProviders: Set<UsageProvider> = []) {
    self.disabledProviders = disabledProviders
  }
}

@MainActor
@Observable
final class ProviderActivationController {
  static let defaultsKey = "providerActivation.preferences.v1"

  private(set) var preferences: ProviderActivationPreferences

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    guard defaults.object(forKey: Self.defaultsKey) != nil else {
      preferences = ProviderActivationPreferences()
      return
    }

    if let data = defaults.data(forKey: Self.defaultsKey),
       let restored = try? JSONDecoder().decode(ProviderActivationPreferences.self, from: data) {
      preferences = restored
    } else {
      let fallback = ProviderActivationPreferences()
      preferences = fallback
      Self.save(fallback, defaults: defaults)
    }
  }

  func isEnabled(_ provider: UsageProvider) -> Bool {
    !preferences.disabledProviders.contains(provider)
  }

  @discardableResult
  func setProvider(_ provider: UsageProvider, enabled: Bool) -> Bool {
    var updated = preferences
    let didChange = if enabled {
      updated.disabledProviders.remove(provider) != nil
    } else {
      updated.disabledProviders.insert(provider).inserted
    }
    guard didChange else { return false }

    preferences = updated
    persist()
    return true
  }

  private func persist() {
    Self.save(preferences, defaults: defaults)
  }

  private static func save(_ preferences: ProviderActivationPreferences, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}
