import Foundation

public enum UsageFormatter {
  public static func percent(_ value: Double) -> String {
    if value > 0, value < 1 { return "<1%" }
    return "\(Int(value.rounded()))%"
  }

  /// "1h 13m", "1d 14h", "45m" — nil for non-positive intervals.
  public static func compactDuration(_ seconds: TimeInterval) -> String? {
    let total = Int(seconds)
    guard total > 0 else { return nil }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }

  /// "in 2h 5m" / "now"
  public static func resetCountdown(to date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return "now" }
    return compactDuration(seconds).map { "in \($0)" }
  }

  /// "8% in deficit" / "56% in reserve" — nil within 1% of the expected pace.
  public static func paceTrend(_ pace: UsagePace) -> String? {
    let magnitude = abs(pace.deltaPercent)
    guard magnitude >= 1 else { return nil }
    return pace.isDeficit
      ? "\(Int(magnitude.rounded()))% in deficit"
      : "\(Int(magnitude.rounded()))% in reserve"
  }

  /// "Runs out in 1h 13m" / "Lasts until reset · 1.5x headroom" / "Lasts until reset".
  public static func paceProjection(_ pace: UsagePace) -> String {
    if let runsOut = pace.runsOutIn, let text = compactDuration(runsOut) {
      return "Runs out in \(text)"
    }
    if let headroom = pace.headroomMultiplier, headroom >= 1.2, headroom <= 5 {
      return "Lasts until reset · \(String(format: "%.1f", headroom))x headroom"
    }
    return "Lasts until reset"
  }

  /// "$30.47" — fixed en_US formatting for consistent width regardless of locale.
  public static func currency(_ amount: Double, code: String = "USD") -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: amount as NSNumber) ?? "\(amount)"
  }

  /// "952M", "32K", "1.2B" tokens.
  public static func tokens(_ count: Int) -> String {
    let value = Double(count)
    switch value {
    case 1_000_000_000...:
      return "\(trimmed(value / 1_000_000_000))B"
    case 1_000_000...:
      return "\(trimmed(value / 1_000_000))M"
    case 1000...:
      return "\(trimmed(value / 1000))K"
    default:
      return "\(count)"
    }
  }

  private static func trimmed(_ value: Double) -> String {
    value < 10
      ? String(format: "%.1f", value)
      : "\(Int(value.rounded()))"
  }
}
