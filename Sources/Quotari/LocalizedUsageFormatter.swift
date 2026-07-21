import Foundation
import QuotariCore

enum LocalizedUsageFormatter {
  static func percent(_ value: Double) -> String {
    UsageFormatter.percent(value)
  }

  static func compactDuration(
    _ seconds: TimeInterval,
    locale: Locale? = nil
  ) -> String? {
    let total = Int(seconds)
    guard total > 0 else { return nil }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours >= 24 {
      return L10n.string("\(hours / 24)d \(hours % 24)h", locale: locale)
    }
    if hours > 0 {
      return L10n.string("\(hours)h \(minutes)m", locale: locale)
    }
    return L10n.string("\(minutes)m", locale: locale)
  }

  static func resetCountdown(
    to date: Date?,
    now: Date = Date(),
    locale: Locale? = nil
  ) -> String? {
    guard let date else { return nil }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 {
      return L10n.string("now", locale: locale)
    }
    return compactDuration(seconds, locale: locale).map {
      L10n.string("in \($0)", locale: locale)
    }
  }

  static func paceTrend(
    _ pace: UsagePace,
    locale: Locale? = nil
  ) -> String? {
    let magnitude = Int(abs(pace.deltaPercent).rounded())
    guard magnitude >= 1 else { return nil }
    return pace.isDeficit
      ? L10n.string("\(magnitude)% in deficit", locale: locale)
      : L10n.string("\(magnitude)% in reserve", locale: locale)
  }

  static func paceProjection(
    _ pace: UsagePace,
    locale: Locale? = nil
  ) -> String {
    if let runsOut = pace.runsOutIn,
       let text = compactDuration(runsOut, locale: locale) {
      return L10n.string("Runs out in \(text)", locale: locale)
    }
    if let headroom = pace.headroomMultiplier,
       headroom >= 1.2,
       headroom <= 5 {
      let locale = locale ?? L10n.appLocale
      let value = headroom.formatted(
        .number
          .locale(locale)
          .precision(.fractionLength(1))
      )
      return L10n.string("Lasts until reset · \(value)x headroom", locale: locale)
    }
    return L10n.string("Lasts until reset", locale: locale)
  }

  static func currency(
    _ amount: Double,
    code: String = "USD",
    locale: Locale? = nil
  ) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.locale = locale ?? L10n.appLocale
    return formatter.string(from: amount as NSNumber) ?? "\(amount)"
  }

  static func tokens(_ count: Int) -> String {
    UsageFormatter.tokens(count)
  }
}
