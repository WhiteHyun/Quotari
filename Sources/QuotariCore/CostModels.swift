import Foundation

/// Spend + token usage on one day, for the 30-day cost chart.
public struct DailyCost: Codable, Equatable, Sendable, Identifiable {
  public var date: Date
  public var spend: Double
  public var tokens: Int
  public var id: Date {
    date
  }

  public init(date: Date, spend: Double, tokens: Int) {
    self.date = date
    self.spend = spend
    self.tokens = tokens
  }
}

/// How much of a local token estimate had an exact model price available.
public enum CostEstimateAvailability: Equatable, Sendable {
  case complete
  case partial
  case unavailable
}

public struct CostEstimateCoverage: Codable, Equatable, Sendable {
  public var pricedTokens: Int
  public var unpricedTokens: Int
  public var unpricedModels: [String]
  public var usesStalePricing: Bool

  public init(
    pricedTokens: Int,
    unpricedTokens: Int,
    unpricedModels: [String] = [],
    usesStalePricing: Bool = false
  ) {
    self.pricedTokens = pricedTokens
    self.unpricedTokens = unpricedTokens
    self.unpricedModels = unpricedModels
    self.usesStalePricing = usesStalePricing
  }

  public var isComplete: Bool {
    availability == .complete
  }

  public var availability: CostEstimateAvailability {
    if pricedTokens == 0, unpricedTokens > 0 {
      return .unavailable
    }
    if unpricedTokens > 0 {
      return .partial
    }
    return .complete
  }
}

/// Cost/token usage for a provider, either estimated locally or reported by a
/// live provider endpoint.
public struct CostSummary: Codable, Equatable, Sendable {
  public var currencyCode: String
  public var todaySpend: Double
  public var monthSpend: Double
  public var monthTokens: Int
  public var latestTokens: Int
  public var topModel: String?
  public var todaySpendLabel: String
  public var monthSpendLabel: String
  public var sourceDescription: String
  public var estimateCoverage: CostEstimateCoverage?
  /// Chronological, one entry per day (oldest first).
  public var daily: [DailyCost]

  public init(
    currencyCode: String = "USD",
    todaySpend: Double,
    monthSpend: Double,
    monthTokens: Int,
    latestTokens: Int,
    topModel: String? = nil,
    todaySpendLabel: String = "Today",
    monthSpendLabel: String = "30d cost",
    sourceDescription: String = "Estimated from local logs",
    estimateCoverage: CostEstimateCoverage? = nil,
    daily: [DailyCost] = []
  ) {
    self.currencyCode = currencyCode
    self.todaySpend = todaySpend
    self.monthSpend = monthSpend
    self.monthTokens = monthTokens
    self.latestTokens = latestTokens
    self.topModel = topModel
    self.todaySpendLabel = todaySpendLabel
    self.monthSpendLabel = monthSpendLabel
    self.sourceDescription = sourceDescription
    self.estimateCoverage = estimateCoverage
    self.daily = daily
  }

  public var peakSpend: Double {
    daily.map(\.spend).max() ?? 0
  }

  public var hasTokenMetrics: Bool {
    monthTokens > 0 || latestTokens > 0 || daily.contains { $0.tokens > 0 }
  }
}
