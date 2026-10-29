import Foundation
import QuotariCore
import SwiftUI

struct ProviderBalanceRowsView: View {
  let rows: [ProviderBalanceRow]

  var body: some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(rows, id: \.title) { row in
          HStack {
            Text(row.title)
            Spacer()
            Text(row.value).monospacedDigit()
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .combine)
        }
      }
    }
  }
}

struct ProviderBalanceRow: Equatable {
  let title: String
  let value: String
}

/// Provider-reported balances for a card. They come from the live usage
/// response, so they appear whether or not local Usage Insights exist.
enum ProviderBalanceRows {
  static func rows(for snapshot: UsageSnapshot, locale: Locale? = nil) -> [ProviderBalanceRow] {
    var rows: [ProviderBalanceRow] = []
    if let extra = snapshot.extraUsage {
      rows.append(ProviderBalanceRow(
        title: L10n.string("Extra usage", locale: locale),
        value: extraUsageValue(extra, locale: locale)
      ))
    }
    if let credits = snapshot.credits, let value = creditsValue(credits, locale: locale) {
      rows.append(ProviderBalanceRow(title: L10n.string("Credits", locale: locale), value: value))
    }
    if let resets = snapshot.availableResetCredits, resets > 0 {
      rows.append(ProviderBalanceRow(
        title: L10n.string("Reset credits", locale: locale),
        value: L10n.string("\(resets) available", locale: locale)
      ))
    }
    return rows
  }

  private static func creditsValue(_ credits: CreditBalance, locale: Locale?) -> String? {
    if credits.isUnlimited {
      return L10n.string("Unlimited", locale: locale)
    }
    return credits.balance.map { $0.formatted(.number.locale(locale ?? L10n.appLocale)) }
  }

  private static func extraUsageValue(_ extra: ExtraUsage, locale: Locale?) -> String {
    let used = LocalizedUsageFormatter.currency(extra.used, code: extra.currencyCode, locale: locale)
    guard let limit = extra.limit else { return used }
    let cap = LocalizedUsageFormatter.currency(limit, code: extra.currencyCode, locale: locale)
    return L10n.string("\(used) of \(cap)", locale: locale)
  }
}
