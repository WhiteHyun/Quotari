import Foundation

extension QuotaNotificationController {
  static func load<Value: Decodable>(
    _ type: Value.Type,
    key: String,
    defaults: UserDefaults
  ) -> Value? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  static func save(
    _ value: some Encodable,
    key: String,
    defaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  static func normalized(
    _ preferences: QuotaNotificationPreferences
  ) -> QuotaNotificationPreferences {
    var preferences = preferences
    preferences.warningThreshold = min(max(preferences.warningThreshold, 1), 99)
    preferences.criticalThreshold = min(
      max(preferences.criticalThreshold, preferences.warningThreshold + 1),
      100
    )
    return preferences
  }
}
