import Foundation
import QuotariCore

/// Today's locally estimated cost for one provider's insights scope.
struct TodayCost: Equatable {
  var scopeKey: UsageInsightsScopeKey
  var day: Date
  var amount: Double
  /// Partially priced, or read from a cache shared by several accounts.
  var isEstimate: Bool
  var isAccountSpecific: Bool
  var generatedAt: Date
}

enum TodayCostResolution: Equatable {
  case cost(TodayCost)
  /// Today's row can't be priced right now; the last value for this scope and day stands.
  case keepPrevious(scopeKey: UsageInsightsScopeKey, day: Date)
  case unavailable
}

/// Pure rules for showing today's cost beside the menu-bar mascot.
enum MenuBarCostDisplay {
  static func resolve(
    _ state: UsageInsightsLoadState,
    now: Date,
    calendar: Calendar = .current
  ) -> TodayCostResolution {
    // After local midnight, yesterday's summary no longer says anything about today.
    guard let summary = state.summary,
          summary.matchesCalendarWindow(at: now, calendar: calendar),
          let today = summary.daily.last
    else { return .unavailable }
    let isAccountSpecific = summary.accountScope == .exact
    let cost = { (amount: Double, isPartial: Bool) in
      TodayCost(
        scopeKey: summary.scopeKey,
        day: today.date,
        amount: amount,
        isEstimate: isPartial || !isAccountSpecific,
        isAccountSpecific: isAccountSpecific,
        generatedAt: summary.generatedAt
      )
    }
    switch today.spend {
    case let .available(amount):
      return .cost(cost(amount, false))
    case let .partial(amount, _):
      return .cost(cost(amount, true))
    case .unavailable(.unsupportedTokenFields):
      return .keepPrevious(scopeKey: summary.scopeKey, day: today.date)
    case .unavailable:
      return .unavailable
    }
  }

  static func current(_ resolution: TodayCostResolution, remembered: TodayCost?) -> TodayCost? {
    switch resolution {
    case let .cost(cost):
      cost
    case let .keepPrevious(scopeKey, day):
      remembered.flatMap { $0.scopeKey == scopeKey && $0.day == day ? $0 : nil }
    case .unavailable:
      nil
    }
  }

  static func text(_ cost: TodayCost, currencyCode: String = "USD", locale: Locale? = nil) -> String {
    let amount = LocalizedUsageFormatter.currency(cost.amount, code: currencyCode, locale: locale)
    return cost.isEstimate ? "≈\(amount)" : amount
  }

  /// Spells out coverage in words, since "≈" is not announced meaningfully.
  static func accessibilityLabel(
    providerName: String?,
    cost: TodayCost?,
    now: Date,
    currencyCode: String = "USD",
    locale: Locale? = nil
  ) -> String {
    guard let providerName else {
      return L10n.string("Quotari, no cost source selected", locale: locale)
    }
    guard let cost else {
      return L10n.string("Quotari, \(providerName) cost today unavailable", locale: locale)
    }
    let amount = LocalizedUsageFormatter.currency(cost.amount, code: currencyCode, locale: locale)
    var parts = [L10n.string("Quotari, \(providerName) cost today \(amount)", locale: locale)]
    if cost.isEstimate {
      parts.append(L10n.string("estimate", locale: locale))
    }
    if !cost.isAccountSpecific {
      parts.append(L10n.string("not account-specific", locale: locale))
    }
    let freshness = ProviderFreshness(updatedAt: cost.generatedAt, now: now, refreshInterval: 0)
    parts.append(freshness.updatedText.lowercased())
    return parts.joined(separator: ", ")
  }
}
