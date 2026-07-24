import Foundation
import QuotariCore

enum UsageInsightCellKind: String {
  case topModel
  case cache
  case sessions
}

struct UsageInsightsPresentation: Equatable {
  enum Metric: Equatable {
    case spend(currencyCode: String)
    case tokens
  }

  struct Point: Equatable, Identifiable {
    let date: Date
    let value: Double?

    var id: Date {
      date
    }
  }

  struct InsightCell: Equatable, Identifiable {
    let kind: UsageInsightCellKind
    let title: String
    let value: String
    let systemImage: String

    var id: UsageInsightCellKind {
      kind
    }
  }

  struct Coverage: Equatable {
    let label: String
    let help: String
    let isWarning: Bool
  }

  let period: UsageInsightsPeriod
  let metric: Metric
  let todayValue: String
  let periodLabel: String
  let periodValue: String
  let points: [Point]
  let average: Double
  let averageValue: String
  let insightCells: [InsightCell]
  let coverageLabel: String
  let coverageHelp: String
  let coverageIsWarning: Bool

  var compactAccessibilityValue: String {
    [
      "\(L10n.string("Today")): \(todayValue)",
      "\(periodLabel): \(periodValue)",
    ]
    .joined(separator: ", ")
  }

  init?(
    summary: UsageInsightsSummary,
    period: UsageInsightsPeriod,
    currencyCode: String = "USD"
  ) {
    guard let periodSummary = summary.period(period),
          let today = periodSummary.daily.last
    else { return nil }

    self.period = period
    periodLabel = period == .sevenDays ? L10n.string("7d") : L10n.string("30d")

    if Self.shouldUseSpend(periodSummary) {
      metric = .spend(currencyCode: currencyCode)
      todayValue = Self.formattedSpend(today.spend, currencyCode: currencyCode)
      periodValue = Self.formattedSpend(periodSummary.spend, currencyCode: currencyCode)
      points = periodSummary.daily.map {
        Point(date: $0.date, value: $0.spend.value)
      }
    } else if case let .available(totalTokens) = periodSummary.tokens.total {
      metric = .tokens
      todayValue = Self.formattedTokens(today.tokens.total)
      periodValue = LocalizedUsageFormatter.tokens(totalTokens)
      points = periodSummary.daily.map {
        Point(date: $0.date, value: $0.tokens.total.value.map(Double.init))
      }
    } else {
      return nil
    }

    let availableValues = points.compactMap(\.value)
    average = availableValues.isEmpty
      ? 0
      : availableValues.reduce(0, +) / Double(availableValues.count)
    averageValue = Self.formattedAverage(average, metric: metric)
    insightCells = Self.insightCells(periodSummary)
    let coverage = Self.coverage(summary: summary, period: periodSummary, metric: metric)
    coverageLabel = coverage.label
    coverageHelp = coverage.help
    coverageIsWarning = coverage.isWarning
  }

  private static func shouldUseSpend(_ period: UsageInsightsPeriodSummary) -> Bool {
    period.spend.value != nil && period.pricingCoverage.availability != .unavailable
  }

  private static func formattedSpend(
    _ metric: UsageMetric<Double>,
    currencyCode: String
  ) -> String {
    guard let value = metric.value else { return "—" }
    let prefix = if case .partial = metric {
      "≈"
    } else {
      ""
    }
    return prefix + LocalizedUsageFormatter.currency(value, code: currencyCode)
  }

  private static func formattedTokens(_ metric: UsageMetric<Int>) -> String {
    guard let value = metric.value else { return "—" }
    let prefix = if case .partial = metric {
      "≈"
    } else {
      ""
    }
    return prefix + LocalizedUsageFormatter.tokens(value)
  }

  private static func formattedAverage(_ average: Double, metric: Metric) -> String {
    switch metric {
    case let .spend(currencyCode):
      LocalizedUsageFormatter.currency(average, code: currencyCode)
    case .tokens:
      LocalizedUsageFormatter.tokens(Int(average.rounded()))
    }
  }

  private static func insightCells(
    _ period: UsageInsightsPeriodSummary
  ) -> [InsightCell] {
    var cells: [InsightCell] = []
    if let topModel = period.topModel {
      cells.append(InsightCell(
        kind: .topModel,
        title: L10n.string("Top model"),
        value: topModel.modelID,
        systemImage: "cube"
      ))
    }
    if case let .available(efficiency) = period.cacheEfficiency {
      cells.append(InsightCell(
        kind: .cache,
        title: L10n.string("Cache"),
        value: efficiency.formatted(.percent.precision(.fractionLength(0))),
        systemImage: "externaldrive"
      ))
    }
    if case let .available(count) = period.sessionCount {
      cells.append(InsightCell(
        kind: .sessions,
        title: L10n.string("Sessions"),
        value: count.formatted(),
        systemImage: "person.2"
      ))
    }
    return cells
  }

  private static func coverage(
    summary: UsageInsightsSummary,
    period: UsageInsightsPeriodSummary,
    metric: Metric
  ) -> Coverage {
    var details: [String] = []
    switch metric {
    case .tokens:
      details.append(L10n.string("Pricing unavailable"))
    case .spend:
      switch period.pricingCoverage.availability {
      case .partial:
        details.append(L10n.string("Partial pricing"))
      case .unavailable:
        details.append(L10n.string("Pricing unavailable"))
      case .complete:
        switch period.spend.availability {
        case .available:
          break
        case let .partial(limitation):
          details.append(coverageDetail(for: limitation))
        case let .unavailable(limitation):
          details.append(coverageDetail(for: limitation))
        }
      }
    }
    if period.pricingCoverage.usesStalePricing,
       !details.contains(L10n.string("Cached pricing")) {
      details.append(L10n.string("Cached pricing"))
    }
    if summary.accountScope == .sharedLocalCache {
      details.append(L10n.string("Not account-specific"))
    }

    let base = metric == .tokens
      ? L10n.string("Local tokens")
      : L10n.string("Estimated locally")
    let label = ([base] + details).joined(separator: " · ")
    let localizedSourceDescription = L10n.string(key: summary.sourceDescription)
    let source = L10n.string("Source: \(localizedSourceDescription)")
    let unpriced = period.pricingCoverage.unpricedModels
    let help = unpriced.isEmpty
      ? source
      : "\(source)\n\(L10n.string("Unpriced models: \(unpriced.joined(separator: ", "))"))"
    return Coverage(label: label, help: help, isWarning: !details.isEmpty)
  }

  private static func coverageDetail(for limitation: UsageMetricLimitation) -> String {
    switch limitation {
    case .missingPricing:
      L10n.string("Partial pricing")
    case .stalePricing:
      L10n.string("Cached pricing")
    case .sharedAccountScope, .unknownAccountScope:
      L10n.string("Not account-specific")
    case .unsupportedTokenFields:
      L10n.string("Partial estimate")
    case .noActivity, .noLocalLogs, .unstableSessionIdentity, .scanFailed:
      L10n.string("Limited coverage")
    }
  }
}
