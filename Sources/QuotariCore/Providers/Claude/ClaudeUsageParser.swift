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
    }
    let mapped = UsageWindowMapper.map(rawWindows)
    // A 200 with no recognizable windows is a failure, not an empty success —
    // otherwise it would suppress the mock fallback and render an empty card.
    guard !mapped.isEmpty else { throw ProviderFetchError.emptyUsage(provider) }

    return UsageSnapshot(
      provider: provider,
      plan: string(root["subscription_type"]) ?? string(root["rate_limit_tier"]),
      account: string(root["email"]) ?? string(root["account_email"]),
      primary: mapped.primary,
      secondary: mapped.secondary,
      extraWindows: mapped.extraWindows,
      updatedAt: now
    )
  }

  private static func rawWindow(key: String, fields: [String: Any], now: Date) -> RawUsageWindow? {
    // A window object without any utilization signal is not a real window.
    let used = number(fields["utilization"]) ?? number(fields["used_percent"])
    let remaining = number(fields["remaining_percent"])
    guard used != nil || remaining != nil else { return nil }

    var resetsAt: Date?
    if let epoch = number(fields["resets_at"]) {
      resetsAt = Date(timeIntervalSince1970: epoch)
    } else if let iso = string(fields["resets_at"]) {
      resetsAt = ISO8601DateFormatter().date(from: iso)
    }

    return RawUsageWindow(
      key: key,
      usedPercent: used,
      remainingPercent: remaining,
      resetsAt: resetsAt,
      duration: number(fields["window_seconds"]),
      label: string(fields["label"])
    )
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
