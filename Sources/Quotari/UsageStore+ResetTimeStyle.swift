import Foundation

extension UsageStore {
  /// How quota rows say when a window resets, restored from or written to defaults.
  var resetTimeStyle: ResetTimeStyle {
    get {
      storedResetTimeStyle
        ?? ResetTimeStyle(rawValue: defaults.string(forKey: Self.resetTimeStyleDefaultsKey) ?? "")
        ?? .countdown
    }
    set {
      storedResetTimeStyle = newValue
      defaults.set(newValue.rawValue, forKey: Self.resetTimeStyleDefaultsKey)
    }
  }
}
