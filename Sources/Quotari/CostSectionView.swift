import Charts
import QuotariCore
import SwiftUI

/// The cost block: a Today / 30-day spend + tokens grid, top model, and a
/// 30-day spend bar chart. Accent-colored to match the provider.
struct CostSectionView: View {
  let cost: CostSummary
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      grid
      if showsMonetaryMetrics, !cost.daily.isEmpty {
        chart
      }
      if let model = cost.topModel {
        Text(L10n.string("Top model: \(model)"))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let pricingStatusMessage {
        Text(pricingStatusMessage)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      if cost.estimateCoverage?.usesStalePricing == true {
        Text(L10n.string("Using cached pricing"))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Text(localizedCostMetadata(cost.sourceDescription))
        .font(.caption2).foregroundStyle(.tertiary)
    }
  }

  private var grid: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
      if showsMonetaryMetrics {
        GridRow {
          metric(
            localizedCostMetadata(cost.todaySpendLabel),
            LocalizedUsageFormatter.currency(cost.todaySpend, code: cost.currencyCode)
          )
          metric(
            localizedCostMetadata(cost.monthSpendLabel),
            LocalizedUsageFormatter.currency(cost.monthSpend, code: cost.currencyCode)
          )
        }
      }
      if cost.hasTokenMetrics {
        GridRow {
          metric(L10n.string("30d tokens"), LocalizedUsageFormatter.tokens(cost.monthTokens))
          metric(L10n.string("Latest tokens"), LocalizedUsageFormatter.tokens(cost.latestTokens))
        }
      }
    }
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.callout.weight(.semibold).monospacedDigit())
    }
  }

  var showsMonetaryMetrics: Bool {
    cost.estimateCoverage?.availability != .unavailable
  }

  var pricingStatusMessage: String? {
    if let coverage = cost.estimateCoverage {
      let unavailableDetail = unavailablePricingDetail(coverage)
      switch coverage.availability {
      case .complete:
        break
      case .partial:
        return L10n.string("Partial estimate\(unavailableDetail)")
      case .unavailable:
        return L10n.string("Cost unavailable\(unavailableDetail)")
      }
    }
    return cost.estimateLimitation.map(estimateLimitationMessage)
  }

  private func estimateLimitationMessage(_ limitation: UsageMetricLimitation) -> String {
    switch limitation {
    case .unsupportedTokenFields:
      L10n.string("Partial estimate · unsupported token fields")
    case .sharedAccountScope:
      L10n.string("Partial estimate · not account-specific")
    case .noActivity, .noLocalLogs, .unknownAccountScope, .unstableSessionIdentity,
         .missingPricing, .stalePricing, .scanFailed:
      L10n.string("Partial estimate")
    }
  }

  private func unavailablePricingDetail(_ coverage: CostEstimateCoverage) -> String {
    let visibleModels = coverage.unpricedModels.prefix(2)
    guard !visibleModels.isEmpty else { return "" }
    let names = visibleModels.joined(separator: ", ")
    let remaining = coverage.unpricedModels.count - visibleModels.count
    let suffix = remaining > 0 ? " +\(remaining)" : ""
    return L10n.string(" · pricing unavailable for \(names)\(suffix)")
  }

  private func localizedCostMetadata(_ value: String) -> String {
    let localizedValues = [
      "Today": L10n.string("Today"),
      "30d cost": L10n.string("30d cost"),
      "Reported": L10n.string("Reported"),
      "Period cost": L10n.string("Period cost"),
      "Estimated from local logs": L10n.string("Estimated from local logs"),
      "Estimated from local Codex logs": L10n.string("Estimated from local Codex logs"),
      "Estimated from local Codex logs (not account-specific)":
        L10n.string("Estimated from local Codex logs (not account-specific)"),
      "Estimated from local Claude cache logs": L10n.string("Estimated from local Claude cache logs"),
      "Estimated from selected account's local Codex logs":
        L10n.string("Estimated from selected account's local Codex logs"),
      "Estimated from selected account's local Claude cache logs":
        L10n.string("Estimated from selected account's local Claude cache logs"),
      "Estimated from local Claude cache logs (not account-specific)":
        L10n.string("Estimated from local Claude cache logs (not account-specific)"),
      "Saved account — local Codex cost estimate unavailable":
        L10n.string("Saved account — local Codex cost estimate unavailable"),
      "Saved account — local Claude cost estimate unavailable":
        L10n.string("Saved account — local Claude cost estimate unavailable"),
      "Reported usage credits": L10n.string("Reported usage credits"),
      "Reported by provider": L10n.string("Reported by provider"),
    ]
    return localizedValues[value] ?? value
  }

  private var chart: some View {
    Chart(cost.daily) { day in
      BarMark(
        x: .value(L10n.string("Day"), day.date, unit: .day),
        y: .value(L10n.string("Spend"), day.spend)
      )
      .foregroundStyle(Theme.accent(accent, intensity: cost.peakSpend > 0 ? day.spend / cost.peakSpend : 0))
      .cornerRadius(1)
    }
    .chartYAxis(.hidden)
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: 10)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
          .font(.caption2)
      }
    }
    .frame(height: 56)
  }
}
