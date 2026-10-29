import Foundation

enum RefreshMode: String, CaseIterable, Codable, Sendable {
  case adaptive
  case fixed
}

/// Chooses the wait before the next scheduled refresh.
enum RefreshCadence {
  static let minimum: TimeInterval = 60
  static let idleCeiling: TimeInterval = 30 * 60
  static let backoffCeiling: TimeInterval = 60 * 60

  /// `base` is the interval chosen in Settings. Adaptive mode refreshes faster
  /// while someone is working and slower while idle, but idle never refreshes
  /// more often than `base`. Requests the rate-limit gate blocks stay blocked.
  static func interval(
    base: TimeInterval,
    mode: RefreshMode,
    isActive: Bool,
    wasRateLimited: Bool
  ) -> TimeInterval {
    guard mode == .adaptive else { return base }
    let idle = max(base, min(base * 2, idleCeiling))
    if wasRateLimited {
      return min(idle * 2, backoffCeiling)
    }
    return isActive ? max(minimum, base / 2) : idle
  }
}
