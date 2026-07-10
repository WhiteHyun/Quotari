import Foundation

/// Parses the Codex usage endpoint into a `UsageSnapshot`, going through the
/// generic window mapper so unknown/renamed rate-limit windows pass through as
/// named extras instead of being dropped.
///
/// The payload is undocumented. The observed shape nests the plan windows as
/// `rate_limit: { primary_window, secondary_window }` (each `{ used_percent,
/// reset_at/reset_after_seconds, limit_window_seconds }`) with model-specific limits in
/// `additional_rate_limits: [ { limit_name, rate_limit } ]`. A flat
/// `rate_limits` list or dict is kept as a fallback shape.
public enum CodexUsageParser {
  public static func parse(_ data: Data, provider: UsageProvider, now: Date) throws -> UsageSnapshot {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProviderFetchError.noStrategyAvailable(provider)
    }

    var rawWindows = coreWindows(from: root, now: now) + additionalLimitWindows(from: root, now: now)
    if rawWindows.isEmpty {
      rawWindows = rateLimitEntries(from: root).map { entry in
        rawWindow(key: entry.key, fields: entry.fields, now: now)
      }
    }
    let mapped = UsageWindowMapper.map(rawWindows)
    // A 200 with no recognizable windows is a failure, not an empty success —
    // otherwise it would suppress the mock fallback and render an empty card.
    guard !mapped.isEmpty else { throw ProviderFetchError.emptyUsage(provider) }

    return UsageSnapshot(
      provider: provider,
      plan: PlanLabel.codex(string(root["plan"]) ?? string(root["plan_type"])),
      account: string(root["account_email"]) ?? string(root["email"]),
      primary: mapped.primary,
      secondary: mapped.secondary,
      extraWindows: mapped.extraWindows,
      cost: LiveCostSummaryParser.parse(root, now: now),
      updatedAt: now
    )
  }

  // MARK: - Observed shape

  private static func coreWindows(from root: [String: Any], now: Date) -> [RawUsageWindow] {
    guard let rateLimit = root["rate_limit"] as? [String: Any] else { return [] }
    let slots = [("primary_window", "session"), ("secondary_window", "weekly")]
    return slots.compactMap { field, key in
      (rateLimit[field] as? [String: Any]).map { rawWindow(key: key, fields: $0, now: now) }
    }
  }

  private static func additionalLimitWindows(from root: [String: Any], now: Date) -> [RawUsageWindow] {
    guard let entries = root["additional_rate_limits"] as? [[String: Any]] else { return [] }
    return entries.flatMap { entry -> [RawUsageWindow] in
      guard let rateLimit = entry["rate_limit"] as? [String: Any],
            let name = string(entry["limit_name"]) ?? string(entry["metered_feature"])
      else { return [] }

      let slots: [(field: String, fallbackSuffix: String)] = [
        ("primary_window", "5-hour"), ("secondary_window", "Weekly"),
      ]
      let present = slots.compactMap { slot in
        (rateLimit[slot.field] as? [String: Any]).map { ($0, slot.fallbackSuffix) }
      }
      return present.map { fields, fallbackSuffix in
        var window = rawWindow(key: name, fields: fields, now: now)
        // One named limit can carry both a short and a weekly window; suffix
        // the titles so the rows stay distinguishable.
        let title = present.count > 1
          ? "\(name) \(window.duration.flatMap { durationSuffix(for: $0) } ?? fallbackSuffix)"
          : name
        window.label = title
        window.key = title
        return window
      }
    }
  }

  private static func durationSuffix(for duration: TimeInterval) -> String? {
    if duration >= 6 * 24 * 3600 {
      return "Weekly"
    }
    if duration >= 3600 {
      return "\(Int((duration / 3600).rounded()))-hour"
    }
    return nil
  }

  // MARK: - Fallback shape

  private struct Entry {
    let key: String
    let fields: [String: Any]
  }

  /// Accepts either `rate_limits: [ { window: "...", ... } ]` or
  /// `rate_limits: { "five_hour": { ... } }`, plus a few key aliases.
  private static func rateLimitEntries(from root: [String: Any]) -> [Entry] {
    let container = root["rate_limits"] ?? root["usage"]
    if let array = container as? [[String: Any]] {
      return array.compactMap { fields in
        guard let key = string(fields["window"]) ?? string(fields["name"]) ?? string(fields["key"])
        else { return nil }
        return Entry(key: key, fields: fields)
      }
    }
    if let dict = container as? [String: Any] {
      return dict.compactMap { key, value in
        (value as? [String: Any]).map { Entry(key: key, fields: $0) }
      }
    }
    return []
  }

  private static func rawWindow(key: String, fields: [String: Any], now: Date) -> RawUsageWindow {
    let duration = number(fields["limit_window_seconds"])
      ?? number(fields["window_minutes"]).map { $0 * 60 }
      ?? number(fields["window_seconds"])

    return RawUsageWindow(
      key: key,
      usedPercent: number(fields["used_percent"]),
      remainingPercent: number(fields["remaining_percent"]),
      resetsAt: resetDate(from: fields, now: now),
      duration: duration,
      label: string(fields["label"])
    )
  }

  private static func resetDate(from fields: [String: Any], now: Date) -> Date? {
    if let seconds = number(fields["resets_in_seconds"])
      ?? number(fields["reset_in_seconds"])
      ?? number(fields["reset_after_seconds"]) {
      return now.addingTimeInterval(seconds)
    }

    for key in ["reset_at", "resets_at", "resetAt", "resetsAt", "reset_time", "resetTime"] {
      if let date = LenientDateParser.parse(fields[key]) {
        return date
      }
    }
    return nil
  }

  // MARK: - Lenient scalar readers

  private static func number(_ value: Any?) -> Double? {
    if let double = value as? Double {
      return double
    }
    if let int = value as? Int {
      return Double(int)
    }
    if let string = value as? String {
      return Double(string)
    }
    return nil
  }

  private static func string(_ value: Any?) -> String? {
    (value as? String).flatMap { $0.isEmpty ? nil : $0 }
  }
}
