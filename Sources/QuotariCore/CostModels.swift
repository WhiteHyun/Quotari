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

/// Estimated cost/token usage for a provider, derived from local logs.
public struct CostSummary: Codable, Equatable, Sendable {
  public var currencyCode: String
  public var todaySpend: Double
  public var monthSpend: Double
  public var monthTokens: Int
  public var latestTokens: Int
  public var topModel: String?
  /// Chronological, one entry per day (oldest first).
  public var daily: [DailyCost]

  public init(
    currencyCode: String = "USD",
    todaySpend: Double,
    monthSpend: Double,
    monthTokens: Int,
    latestTokens: Int,
    topModel: String? = nil,
    daily: [DailyCost] = []
  ) {
    self.currencyCode = currencyCode
    self.todaySpend = todaySpend
    self.monthSpend = monthSpend
    self.monthTokens = monthTokens
    self.latestTokens = latestTokens
    self.topModel = topModel
    self.daily = daily
  }

  public var peakSpend: Double {
    daily.map(\.spend).max() ?? 0
  }
}
