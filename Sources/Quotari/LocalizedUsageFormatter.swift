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

  /// The phrase that fills "Resets %@" in the chosen style. A reset that has
  /// already passed reads "now" in every style.
  static func resetPhrase(
    to date: Date?,
    style: ResetTimeStyle,
    now: Date = Date(),
    locale: Locale? = nil,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String? {
    guard let date else { return nil }
    guard date > now else { return L10n.string("now", locale: locale) }
    let countdown = resetCountdown(to: date, now: now, locale: locale)
    switch style {
    case .countdown:
      return countdown
    case .clockTime:
      return resetClockTime(date, now: now, locale: locale, calendar: calendar)
    case .both:
      let clock = resetClockTime(date, now: now, locale: locale, calendar: calendar)
      return countdown.map { "\($0) · \(clock)" } ?? clock
    }
  }

  /// The reset's wall-clock time, coarser the further away it is: a time
  /// today, "tomorrow" and a time, a weekday and a time within the week, then
  /// a date.
  static func resetClockTime(
    _ date: Date,
    now: Date,
    locale: Locale? = nil,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    let formattingLocale = locale ?? L10n.formattingLocale
    var calendar = calendar
    calendar.locale = formattingLocale
    func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
      var style = base
      style.locale = formattingLocale
      style.calendar = calendar
      style.timeZone = calendar.timeZone
      return style
    }
    let time = date.formatted(style(Date.FormatStyle(date: .omitted, time: .shortened)))
    let days = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: now),
      to: calendar.startOfDay(for: date)
    ).day ?? 0
    switch days {
    case ...0:
      return time
    case 1:
      return L10n.string("tomorrow \(time)", locale: locale)
    case 2 ..< 7:
      let weekday = date.formatted(style(Date.FormatStyle().weekday(.abbreviated)))
      return "\(weekday) \(time)"
    default:
      return date.formatted(style(Date.FormatStyle().month(.abbreviated).day()))
    }
  }

  static func paceTrend(
    _ pace: UsagePace,
    locale: Locale? = nil
  ) -> String? {
    let rawMagnitude = abs(pace.deltaPercent)
    guard rawMagnitude >= 1 else { return nil }
    let magnitude = Int(rawMagnitude.rounded())
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

  static func tokenCount(
    _ count: Int,
    locale: Locale? = nil
  ) -> String {
    L10n.string("\(tokens(count)) tokens", locale: locale)
  }
}
