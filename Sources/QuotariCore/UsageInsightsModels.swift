import Foundation

public struct UsageInsightsScopeKey: Codable, Equatable, Hashable, Sendable {
  public var provider: UsageProvider
  public var accountScopeID: String

  public init(provider: UsageProvider, accountScopeID: String) {
    self.provider = provider
    self.accountScopeID = accountScopeID
  }
}

public enum UsageInsightsSource: String, Codable, Equatable, Sendable {
  case localCodexLogs
  case localClaudeCacheLogs
}

public enum UsageInsightsAccountScope: String, Codable, Equatable, Sendable {
  case exact
  case sharedLocalCache
}

public enum UsageInsightsPeriod: Int, CaseIterable, Codable, Equatable, Sendable {
  case sevenDays = 7
  case thirtyDays = 30
}

public enum UsageMetricLimitation: String, Codable, Equatable, Sendable {
  case noActivity
  case noLocalLogs
  case unknownAccountScope
  case sharedAccountScope
  case unsupportedTokenFields
  case unstableSessionIdentity
  case missingPricing
  case stalePricing
  case scanFailed
}

public enum UsageMetricAvailability: Codable, Equatable, Sendable {
  case available
  case partial(UsageMetricLimitation)
  case unavailable(UsageMetricLimitation)
}

public enum UsageMetric<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  case available(Value)
  case partial(value: Value, limitation: UsageMetricLimitation)
  case unavailable(UsageMetricLimitation)

  public var value: Value? {
    switch self {
    case let .available(value), let .partial(value, _):
      value
    case .unavailable:
      nil
    }
  }

  public var availability: UsageMetricAvailability {
    switch self {
    case .available:
      .available
    case let .partial(_, limitation):
      .partial(limitation)
    case let .unavailable(limitation):
      .unavailable(limitation)
    }
  }
}

public struct UsageTokenBreakdown: Codable, Equatable, Sendable {
  public var input: UsageMetric<Int>
  public var output: UsageMetric<Int>
  public var cacheRead: UsageMetric<Int>
  public var cacheWrite: UsageMetric<Int>
  public var total: UsageMetric<Int>

  public init(
    input: UsageMetric<Int>,
    output: UsageMetric<Int>,
    cacheRead: UsageMetric<Int>,
    cacheWrite: UsageMetric<Int>,
    total: UsageMetric<Int>
  ) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.total = total
  }
}

public struct ModelUsageInsight: Codable, Equatable, Identifiable, Sendable {
  public var modelID: String
  public var spend: UsageMetric<Double>
  public var tokens: UsageTokenBreakdown
  public var pricingCoverage: CostEstimateCoverage

  public var id: String {
    modelID
  }

  public init(
    modelID: String,
    spend: UsageMetric<Double>,
    tokens: UsageTokenBreakdown,
    pricingCoverage: CostEstimateCoverage
  ) {
    self.modelID = modelID
    self.spend = spend
    self.tokens = tokens
    self.pricingCoverage = pricingCoverage
  }
}

public struct DailyUsageInsight: Codable, Equatable, Identifiable, Sendable {
  public var date: Date
  public var spend: UsageMetric<Double>
  public var tokens: UsageTokenBreakdown
  public var sessionCount: UsageMetric<Int>
  public var models: [ModelUsageInsight]
  public var pricingCoverage: CostEstimateCoverage
  var sessionKeys: [String]

  public var id: Date {
    date
  }

  public init(
    date: Date,
    spend: UsageMetric<Double>,
    tokens: UsageTokenBreakdown,
    sessionCount: UsageMetric<Int>,
    models: [ModelUsageInsight],
    pricingCoverage: CostEstimateCoverage
  ) {
    self.init(
      date: date,
      spend: spend,
      tokens: tokens,
      sessionCount: sessionCount,
      models: models,
      pricingCoverage: pricingCoverage,
      sessionKeys: []
    )
  }

  init(
    date: Date,
    spend: UsageMetric<Double>,
    tokens: UsageTokenBreakdown,
    sessionCount: UsageMetric<Int>,
    models: [ModelUsageInsight],
    pricingCoverage: CostEstimateCoverage,
    sessionKeys: [String]
  ) {
    self.date = date
    self.spend = spend
    self.tokens = tokens
    self.sessionCount = sessionCount
    self.models = models
    self.pricingCoverage = pricingCoverage
    self.sessionKeys = sessionKeys
  }
}

public struct UsageInsightsSummary: Codable, Equatable, Sendable {
  public var scopeKey: UsageInsightsScopeKey
  public var generatedAt: Date
  public var source: UsageInsightsSource
  public var accountScope: UsageInsightsAccountScope
  public var sourceDescription: String
  public var daily: [DailyUsageInsight]

  public init(
    scopeKey: UsageInsightsScopeKey,
    generatedAt: Date,
    source: UsageInsightsSource,
    accountScope: UsageInsightsAccountScope,
    sourceDescription: String,
    daily: [DailyUsageInsight]
  ) {
    self.scopeKey = scopeKey
    self.generatedAt = generatedAt
    self.source = source
    self.accountScope = accountScope
    self.sourceDescription = sourceDescription
    self.daily = daily
  }

  public func period(_ period: UsageInsightsPeriod) -> UsageInsightsPeriodSummary? {
    self.period(days: period.rawValue)
  }

  public func period(days: Int) -> UsageInsightsPeriodSummary? {
    guard days > 0, days <= daily.count else { return nil }
    return UsageInsightsPeriodSummary(daily: Array(daily.suffix(days)))
  }
}

public struct UsageInsightsPeriodSummary: Equatable, Sendable {
  public var startDate: Date
  public var endDate: Date
  public var spend: UsageMetric<Double>
  public var tokens: UsageTokenBreakdown
  public var models: [ModelUsageInsight]
  public var sessionCount: UsageMetric<Int>
  public var cacheEfficiency: UsageMetric<Double>
  public var pricingCoverage: CostEstimateCoverage
  public var daily: [DailyUsageInsight]

  public var topModel: ModelUsageInsight? {
    models.sorted(by: Self.modelRanksBefore).first
  }

  init?(daily: [DailyUsageInsight]) {
    guard let startDate = daily.first?.date,
          let endDate = daily.last?.date
    else { return nil }

    self.startDate = startDate
    self.endDate = endDate
    self.daily = daily
    spend = .summing(daily.map(\.spend))
    tokens = .summing(daily.map(\.tokens))
    models = Self.aggregateModels(daily.flatMap(\.models))
    sessionCount = Self.aggregateSessions(daily)
    cacheEfficiency = Self.cacheEfficiency(tokens: tokens)
    pricingCoverage = .summing(daily.map(\.pricingCoverage))
  }

  private static func aggregateModels(_ models: [ModelUsageInsight]) -> [ModelUsageInsight] {
    Dictionary(grouping: models, by: \.modelID)
      .map { modelID, values in
        ModelUsageInsight(
          modelID: modelID,
          spend: .summing(values.map(\.spend)),
          tokens: .summing(values.map(\.tokens)),
          pricingCoverage: .summing(values.map(\.pricingCoverage))
        )
      }
      .sorted { $0.modelID < $1.modelID }
  }

  private static func aggregateSessions(_ daily: [DailyUsageInsight]) -> UsageMetric<Int> {
    let sessionKeys = Set(daily.flatMap(\.sessionKeys))
    let counts = daily.map(\.sessionCount)
    guard !sessionKeys.isEmpty else {
      return .summing(counts)
    }

    let limitation = counts.lazy.compactMap(\.limitation).first
    if let limitation {
      return .partial(value: sessionKeys.count, limitation: limitation)
    }
    return .available(sessionKeys.count)
  }

  private static func cacheEfficiency(tokens: UsageTokenBreakdown) -> UsageMetric<Double> {
    guard case let .available(input) = tokens.input,
          case let .available(cacheRead) = tokens.cacheRead
    else {
      return .unavailable(.unsupportedTokenFields)
    }
    let denominator = input + cacheRead
    guard denominator > 0 else {
      return .unavailable(.noActivity)
    }
    return .available(Double(cacheRead) / Double(denominator))
  }

  private static func modelRanksBefore(_ lhs: ModelUsageInsight, _ rhs: ModelUsageInsight) -> Bool {
    switch (lhs.spend.value, rhs.spend.value) {
    case let (lhsSpend?, rhsSpend?) where lhsSpend != rhsSpend:
      return lhsSpend > rhsSpend
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      break
    }

    let lhsTokens = lhs.tokens.total.value ?? 0
    let rhsTokens = rhs.tokens.total.value ?? 0
    if lhsTokens != rhsTokens {
      return lhsTokens > rhsTokens
    }
    return lhs.modelID < rhs.modelID
  }
}

extension UsageMetric {
  var limitation: UsageMetricLimitation? {
    switch self {
    case .available:
      nil
    case let .partial(_, limitation), let .unavailable(limitation):
      limitation
    }
  }
}

private extension UsageMetric where Value == Int {
  static func summing(_ values: [Self]) -> Self {
    let total = values.compactMap(\.value).reduce(0, +)
    guard let limitation = values.lazy.compactMap(\.limitation).first else {
      return .available(total)
    }
    return values.contains { $0.value != nil }
      ? .partial(value: total, limitation: limitation)
      : .unavailable(limitation)
  }
}

private extension UsageMetric where Value == Double {
  static func summing(_ values: [Self]) -> Self {
    let total = values.compactMap(\.value).reduce(0, +)
    guard let limitation = values.lazy.compactMap(\.limitation).first else {
      return .available(total)
    }
    return values.contains { $0.value != nil }
      ? .partial(value: total, limitation: limitation)
      : .unavailable(limitation)
  }
}

private extension UsageTokenBreakdown {
  static func summing(_ values: [Self]) -> Self {
    Self(
      input: .summing(values.map(\.input)),
      output: .summing(values.map(\.output)),
      cacheRead: .summing(values.map(\.cacheRead)),
      cacheWrite: .summing(values.map(\.cacheWrite)),
      total: .summing(values.map(\.total))
    )
  }
}

private extension CostEstimateCoverage {
  static func summing(_ values: [Self]) -> Self {
    Self(
      pricedTokens: values.reduce(0) { $0 + $1.pricedTokens },
      unpricedTokens: values.reduce(0) { $0 + $1.unpricedTokens },
      unpricedModels: Array(Set(values.flatMap(\.unpricedModels))).sorted(),
      usesStalePricing: values.contains(where: \.usesStalePricing)
    )
  }
}
