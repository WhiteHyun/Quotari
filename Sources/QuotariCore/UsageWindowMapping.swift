import Foundation

/// One rate-limit window as loosely reported by a provider API, before
/// classification. `key` is the provider's raw field name (for example
/// "seven_day" or "seven_day_fable").
public struct RawUsageWindow: Equatable, Sendable {
  public var key: String
  public var usedPercent: Double?
  public var remainingPercent: Double?
  public var resetsAt: Date?
  public var duration: TimeInterval?
  /// Provider-supplied display name; overrides the humanized key when present.
  public var label: String?

  public init(
    key: String,
    usedPercent: Double? = nil,
    remainingPercent: Double? = nil,
    resetsAt: Date? = nil,
    duration: TimeInterval? = nil,
    label: String? = nil
  ) {
    self.key = key
    self.usedPercent = usedPercent
    self.remainingPercent = remainingPercent
    self.resetsAt = resetsAt
    self.duration = duration
    self.label = label
  }
}

/// Classifies raw provider windows into the snapshot's session/weekly slots.
///
/// Providers rename and add rate-limit windows without notice — a model-only
/// window can appear, change key, or vanish between releases. To survive that,
/// only *exact* session/weekly keys get special meaning; every other window
/// passes through as a named extra with a humanized title. New or renamed
/// limits therefore surface immediately instead of disappearing until an app
/// update ships a new mapping.
public enum UsageWindowMapper {
  public struct Mapped: Equatable, Sendable {
    public var primary: RateWindow?
    public var secondary: RateWindow?
    public var extraWindows: [NamedWindow]

    public init(
      primary: RateWindow? = nil,
      secondary: RateWindow? = nil,
      extraWindows: [NamedWindow] = []
    ) {
      self.primary = primary
      self.secondary = secondary
      self.extraWindows = extraWindows
    }
  }

  public static func map(_ raw: [RawUsageWindow]) -> Mapped {
    var mapped = Mapped()
    for window in raw {
      let key = normalize(window.key)
      if sessionKeys.contains(key), mapped.primary == nil {
        mapped.primary = rateWindow(window, key: key, kind: .session)
      } else if weeklyKeys.contains(key), mapped.secondary == nil {
        mapped.secondary = rateWindow(window, key: key, kind: .weekly)
      } else {
        mapped.extraWindows.append(NamedWindow(
          title: window.label ?? humanizedTitle(for: key),
          window: rateWindow(window, key: key, kind: .custom)
        ))
      }
    }
    return mapped
  }

  // MARK: - Classification tables

  private static let sessionKeys: Set<String> = [
    "session", "current_session", "five_hour", "5h", "5_hour",
  ]

  private static let weeklyKeys: Set<String> = [
    "weekly", "week", "current_week", "seven_day", "7d", "7_day",
  ]

  /// Window-length prefixes that can be stripped from a key when naming it and
  /// used to infer a duration when the provider doesn't report one.
  private static let durationPrefixes: [(tokens: [String], duration: TimeInterval)] = [
    (["five", "hour"], 5 * 3600),
    (["seven", "day"], 7 * 24 * 3600),
  ]

  // MARK: - Building blocks

  private static func rateWindow(_ raw: RawUsageWindow, key: String, kind: UsageWindowKind) -> RateWindow {
    let used = raw.usedPercent ?? raw.remainingPercent.map { 100 - $0 } ?? 0
    return RateWindow(
      kind: kind,
      usedPercent: used,
      resetsAt: raw.resetsAt,
      duration: raw.duration ?? inferredDuration(for: key)
    )
  }

  static func normalize(_ key: String) -> String {
    tokens(of: key).joined(separator: "_")
  }

  /// "seven_day_fable" → "Fable"; "daily_routines" → "Daily Routines".
  static func humanizedTitle(for key: String) -> String {
    var parts = tokens(of: key)
    for prefix in durationPrefixes where parts.count > prefix.tokens.count {
      if Array(parts.prefix(prefix.tokens.count)) == prefix.tokens {
        parts.removeFirst(prefix.tokens.count)
        break
      }
    }
    if parts.isEmpty {
      parts = tokens(of: key)
    }
    return parts.map(\.capitalized).joined(separator: " ")
  }

  static func inferredDuration(for key: String) -> TimeInterval? {
    let parts = tokens(of: key)
    for prefix in durationPrefixes where Array(parts.prefix(prefix.tokens.count)) == prefix.tokens {
      return prefix.duration
    }
    return nil
  }

  private static func tokens(of key: String) -> [String] {
    let sanitized = key.lowercased().map { character -> Character in
      character.isLetter || character.isNumber ? character : "_"
    }
    return String(sanitized)
      .split(separator: "_")
      .map(String.init)
  }
}
