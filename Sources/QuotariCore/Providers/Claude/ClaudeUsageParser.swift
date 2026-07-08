import Foundation

/// Parses the Claude OAuth usage endpoint into a `UsageSnapshot`. The API
/// reports windows as root-level objects keyed by name (`five_hour`,
/// `seven_day`, `seven_day_opus`, …), each `{ utilization, resets_at }`;
/// unknown/renamed keys pass through as named extras via the generic mapper.
public enum ClaudeUsageParser {
  /// Root objects that carry a `utilization` field but are not rate windows.
  private static let nonWindowKeys: Set<String> = ["extra_usage"]

  public static func parse(_ data: Data, provider: UsageProvider, now: Date) throws -> UsageSnapshot {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProviderFetchError.noStrategyAvailable(provider)
    }

    let windowsContainer = (root["usage"] as? [String: Any]) ?? root
    let rawWindows: [RawUsageWindow] = windowsContainer.compactMap { key, value in
      guard !nonWindowKeys.contains(key), let fields = value as? [String: Any] else { return nil }
      return rawWindow(key: key, fields: fields, now: now)
    } + scopedLimitWindows(from: root)
    let mapped = UsageWindowMapper.map(rawWindows)
    // A 200 with no recognizable windows is a failure, not an empty success —
    // otherwise it would suppress the mock fallback and render an empty card.
    guard !mapped.isEmpty else { throw ProviderFetchError.emptyUsage(provider) }

    return UsageSnapshot(
      provider: provider,
      plan: PlanLabel.claude(
        subscriptionType: string(root["subscription_type"]),
        rateLimitTier: string(root["rate_limit_tier"])
      ),
      account: string(root["email"]) ?? string(root["account_email"]),
      primary: mapped.primary,
      secondary: mapped.secondary,
      extraWindows: mapped.extraWindows,
      updatedAt: now
    )
  }

  /// Model-scoped weekly limits (e.g. a Fable-only promotional window) arrive
  /// in the `limits` array rather than as root window objects. Only
  /// `group: weekly` + `kind: weekly_scoped` entries become windows — other
  /// kinds mirror the root session/weekly objects and would duplicate them.
  /// `is_active` is deliberately not a filter: enforced scoped limits have
  /// been observed reporting false.
  private static func scopedLimitWindows(from root: [String: Any]) -> [RawUsageWindow] {
    guard let entries = root["limits"] as? [[String: Any]] else { return [] }
    var seenModels = Set<String>()
    return entries.compactMap { entry in
      guard string(entry["group"]) == "weekly",
            string(entry["kind"]) == "weekly_scoped",
            let percent = number(entry["percent"]), percent.isFinite
      else { return nil }
      let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
      guard let name = string(model?["display_name"]) ?? string(model?["id"]),
            seenModels.insert(name).inserted
      else { return nil }

      let resetsAt = resetDate(from: entry)
      let title = "\(name) only"
      return RawUsageWindow(
        key: title,
        usedPercent: percent,
        resetsAt: resetsAt,
        duration: 7 * 24 * 3600,
        label: title
      )
    }
  }

  private static func rawWindow(key: String, fields: [String: Any], now: Date) -> RawUsageWindow? {
    // A window object without any utilization signal is not a real window.
    let used = number(fields["utilization"]) ?? number(fields["used_percent"])
    let remaining = number(fields["remaining_percent"])
    guard used != nil || remaining != nil else { return nil }

    return RawUsageWindow(
      key: key,
      usedPercent: used,
      remainingPercent: remaining,
      resetsAt: resetDate(from: fields, now: now),
      duration: number(fields["window_seconds"]),
      label: string(fields["label"])
    )
  }

  private static func resetDate(from fields: [String: Any], now: Date? = nil) -> Date? {
    if let now,
       let seconds = number(fields["resets_in_seconds"])
       ?? number(fields["reset_in_seconds"])
       ?? number(fields["reset_after_seconds"])
    {
      return now.addingTimeInterval(seconds)
    }

    for key in ["resets_at", "reset_at", "resetsAt", "resetAt", "reset_time", "resetTime"] {
      if let date = LenientDateParser.parse(fields[key]) {
        return date
      }
    }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private static func string(_ value: Any?) -> String? {
    (value as? String).flatMap { $0.isEmpty ? nil : $0 }
  }
}
