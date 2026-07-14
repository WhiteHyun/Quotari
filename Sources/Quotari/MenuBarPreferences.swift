import Foundation
import Observation
import QuotariCore

enum MenuBarUsageSource: Codable, Equatable, Hashable, Sendable {
  case mostConstrained
  case provider(UsageProvider)
}

struct MenuBarPreferences: Codable, Equatable, Hashable, Sendable {
  var showsRemainingPercent: Bool
  var usageSource: MenuBarUsageSource
  var animatesMascot: Bool

  init(
    showsRemainingPercent: Bool = false,
    usageSource: MenuBarUsageSource = .mostConstrained,
    animatesMascot: Bool = true
  ) {
    self.showsRemainingPercent = showsRemainingPercent
    self.usageSource = usageSource
    self.animatesMascot = animatesMascot
  }
}

@MainActor
@Observable
final class MenuBarPreferencesController {
  static let defaultsKey = "menuBar.preferences.v1"

  private(set) var preferences: MenuBarPreferences

  @ObservationIgnored private let defaults: UserDefaults

  var showsRemainingPercent: Bool {
    get { preferences.showsRemainingPercent }
    set { setShowsRemainingPercent(newValue) }
  }

  var usageSource: MenuBarUsageSource {
    get { preferences.usageSource }
    set { setUsageSource(newValue) }
  }

  var animatesMascot: Bool {
    get { preferences.animatesMascot }
    set { setAnimatesMascot(newValue) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    guard defaults.object(forKey: Self.defaultsKey) != nil else {
      preferences = MenuBarPreferences()
      return
    }

    if let data = defaults.data(forKey: Self.defaultsKey),
       let restored = try? JSONDecoder().decode(MenuBarPreferences.self, from: data) {
      preferences = restored
    } else {
      let fallback = MenuBarPreferences()
      preferences = fallback
      Self.save(fallback, defaults: defaults)
    }
  }

  func setShowsRemainingPercent(_ showsRemainingPercent: Bool) {
    guard preferences.showsRemainingPercent != showsRemainingPercent else { return }
    preferences.showsRemainingPercent = showsRemainingPercent
    persist()
  }

  func setUsageSource(_ usageSource: MenuBarUsageSource) {
    guard preferences.usageSource != usageSource else { return }
    preferences.usageSource = usageSource
    persist()
  }

  func setAnimatesMascot(_ animatesMascot: Bool) {
    guard preferences.animatesMascot != animatesMascot else { return }
    preferences.animatesMascot = animatesMascot
    persist()
  }

  private func persist() {
    Self.save(preferences, defaults: defaults)
  }

  private static func save(_ preferences: MenuBarPreferences, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}
