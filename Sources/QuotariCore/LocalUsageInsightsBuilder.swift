import Foundation

enum LocalUsageInsightsBuilder {
  struct Input {
    var provider: UsageProvider
    var records: [LocalTokenRecord]
    var unsupportedUsage: [LocalUnsupportedUsage] = []
    var range: DayRange
    var pricing: LocalModelPricing
    var scopeKey: UsageInsightsScopeKey
    var accountScope: UsageInsightsAccountScope
    var generatedAt: Date
    var sourceDescription: String?
  }

  static func summary(_ input: Input) -> UsageInsightsSummary? {
    var days: [Date: UsageAccumulator] = [:]
    for unsupported in input.unsupportedUsage {
      days[unsupported.day, default: UsageAccumulator()]
        .addUnsupported(sessionID: unsupported.sessionID, model: unsupported.model)
    }
    for record in input.records {
      let priced = input.pricing.price(
        provider: input.provider,
        model: record.model,
        tokens: record.tokens,
        contextInputTokens: record.contextInputTokens
      )
      days[record.day, default: UsageAccumulator()].add(record: record, priced: priced)
    }

    return UsageInsightsSummary(
      scopeKey: input.scopeKey,
      generatedAt: input.generatedAt,
      source: input.provider.insightsSource,
      accountScope: input.accountScope,
      sourceDescription: input.sourceDescription
        ?? input.provider.defaultInsightsSourceDescription(accountScope: input.accountScope),
      daily: input.range.days.map { day in
        days[day, default: UsageAccumulator()].insight(date: day, provider: input.provider)
      }
    )
  }
}

private struct UsageAccumulator {
  var spend = 0.0
  var tokens = TokenAccumulator()
  var pricedTokens = 0
  var unpricedTokens = 0
  var unpricedModels = Set<String>()
  var usesStalePricing = false
  var models: [String: UsageAccumulator] = [:]
  var sessionKeys = Set<String>()
  var hasUnstableSessionIdentity = false
  var hasUnsupportedUsage = false
  var recordCount = 0

  mutating func addUnsupported(sessionID: String?, model: String?) {
    hasUnsupportedUsage = true
    if let sessionID {
      sessionKeys.insert(sessionID)
    } else {
      hasUnstableSessionIdentity = true
    }
    if let model {
      models[model, default: UsageAccumulator()].hasUnsupportedUsage = true
    }
  }

  mutating func add(record: LocalTokenRecord, priced: LocalPricingResult) {
    recordCount += 1
    spend += priced.spend
    tokens.add(record.tokens)
    pricedTokens += priced.pricedTokens
    unpricedTokens += priced.unpricedTokens
    usesStalePricing = usesStalePricing || priced.usesStalePricing

    if let sessionID = record.sessionID {
      sessionKeys.insert(sessionID)
    } else {
      hasUnstableSessionIdentity = true
    }

    if priced.unpricedTokens > 0 {
      unpricedModels.insert(record.model.map(normalizedModelID) ?? "Unknown model")
    }
    if let model = record.model {
      models[model, default: UsageAccumulator()].addModelRecord(record, priced: priced)
    }
  }

  mutating func addModelRecord(_ record: LocalTokenRecord, priced: LocalPricingResult) {
    recordCount += 1
    spend += priced.spend
    tokens.add(record.tokens)
    pricedTokens += priced.pricedTokens
    unpricedTokens += priced.unpricedTokens
    usesStalePricing = usesStalePricing || priced.usesStalePricing
    if priced.unpricedTokens > 0 {
      unpricedModels.insert(record.model.map(normalizedModelID) ?? "Unknown model")
    }
  }

  func insight(date: Date, provider: UsageProvider) -> DailyUsageInsight {
    let coverage = pricingCoverage
    return DailyUsageInsight(
      date: date,
      spend: spendMetric(provider: provider, coverage: coverage),
      tokens: tokenBreakdown(provider: provider),
      sessionCount: sessionMetric,
      models: models.map { model, accumulator in
        ModelUsageInsight(
          modelID: model,
          spend: accumulator.spendMetric(provider: provider, coverage: accumulator.pricingCoverage),
          tokens: accumulator.tokenBreakdown(provider: provider),
          pricingCoverage: accumulator.pricingCoverage
        )
      }
      .sorted { $0.modelID < $1.modelID },
      pricingCoverage: coverage,
      sessionKeys: sessionKeys.sorted()
    )
  }

  private var pricingCoverage: CostEstimateCoverage {
    CostEstimateCoverage(
      pricedTokens: pricedTokens,
      unpricedTokens: unpricedTokens,
      unpricedModels: unpricedModels.sorted(),
      usesStalePricing: usesStalePricing
    )
  }

  private var sessionMetric: UsageMetric<Int> {
    if hasUnstableSessionIdentity {
      return sessionKeys.isEmpty
        ? .unavailable(.unstableSessionIdentity)
        : .partial(value: sessionKeys.count, limitation: .unstableSessionIdentity)
    }
    return .available(sessionKeys.count)
  }

  private func spendMetric(
    provider: UsageProvider,
    coverage: CostEstimateCoverage
  ) -> UsageMetric<Double> {
    if recordCount == 0 {
      return hasUnsupportedUsage
        ? .unavailable(.unsupportedTokenFields)
        : .available(0)
    }
    if coverage.pricedTokens == 0, coverage.unpricedTokens > 0 {
      return .unavailable(.missingPricing)
    }
    if coverage.unpricedTokens > 0 {
      return .partial(value: spend, limitation: .missingPricing)
    }
    if coverage.usesStalePricing {
      return .partial(value: spend, limitation: .stalePricing)
    }
    if provider == .claude {
      return .partial(value: spend, limitation: .unsupportedTokenFields)
    }
    if hasUnsupportedUsage {
      return .partial(value: spend, limitation: .unsupportedTokenFields)
    }
    return .available(spend)
  }

  private func tokenBreakdown(provider: UsageProvider) -> UsageTokenBreakdown {
    switch provider {
    case .codex:
      if hasUnsupportedUsage {
        return UsageTokenBreakdown(
          input: .partial(value: tokens.input, limitation: .unsupportedTokenFields),
          output: .partial(value: tokens.output, limitation: .unsupportedTokenFields),
          cacheRead: .partial(value: tokens.cacheRead, limitation: .unsupportedTokenFields),
          cacheWrite: .partial(value: tokens.cacheWrite, limitation: .unsupportedTokenFields),
          total: .partial(value: tokens.total, limitation: .unsupportedTokenFields)
        )
      }
      return UsageTokenBreakdown(
        input: .available(tokens.input),
        output: .available(tokens.output),
        cacheRead: .available(tokens.cacheRead),
        cacheWrite: .available(tokens.cacheWrite),
        total: .available(tokens.total)
      )
    case .claude:
      if recordCount == 0 {
        return UsageTokenBreakdown(
          input: hasUnsupportedUsage ? .unavailable(.unsupportedTokenFields) : .available(0),
          output: hasUnsupportedUsage ? .unavailable(.unsupportedTokenFields) : .available(0),
          cacheRead: hasUnsupportedUsage ? .unavailable(.unsupportedTokenFields) : .available(0),
          cacheWrite: hasUnsupportedUsage ? .unavailable(.unsupportedTokenFields) : .available(0),
          total: hasUnsupportedUsage ? .unavailable(.unsupportedTokenFields) : .available(0)
        )
      }
      return UsageTokenBreakdown(
        input: .unavailable(.unsupportedTokenFields),
        output: .unavailable(.unsupportedTokenFields),
        cacheRead: hasUnsupportedUsage
          ? .partial(value: tokens.cacheRead, limitation: .unsupportedTokenFields)
          : .available(tokens.cacheRead),
        cacheWrite: hasUnsupportedUsage
          ? .partial(value: tokens.cacheWrite, limitation: .unsupportedTokenFields)
          : .available(tokens.cacheWrite),
        total: .partial(value: tokens.total, limitation: .unsupportedTokenFields)
      )
    }
  }
}

private struct TokenAccumulator {
  var input = 0
  var output = 0
  var cacheRead = 0
  var cacheWrite = 0

  var total: Int {
    input + output + cacheRead + cacheWrite
  }

  mutating func add(_ tokens: TokenTotals) {
    input += tokens.input
    output += tokens.output
    cacheRead += tokens.cacheRead
    cacheWrite += tokens.cacheWrite
  }
}

extension UsageInsightsSummary {
  var costSummary: CostSummary? {
    guard let period = period(days: daily.count) else { return nil }
    let monthSpend = period.spend.value ?? 0
    let monthTokens = period.tokens.total.value ?? 0
    guard monthSpend > 0 || monthTokens > 0 else { return nil }

    let dailyCost = daily.map { day in
      DailyCost(
        date: day.date,
        spend: day.spend.value ?? 0,
        tokens: day.tokens.total.value ?? 0
      )
    }
    return CostSummary(
      todaySpend: daily.last?.spend.value ?? 0,
      monthSpend: monthSpend,
      monthTokens: monthTokens,
      latestTokens: dailyCost.last(where: { $0.tokens > 0 })?.tokens ?? 0,
      topModel: period.topModel?.modelID,
      monthSpendLabel: daily.count == 30 ? "30d cost" : "\(daily.count)d cost",
      sourceDescription: sourceDescription,
      estimateCoverage: period.pricingCoverage,
      estimateLimitation: legacyEstimateLimitation(period: period),
      daily: dailyCost
    )
  }

  private func legacyEstimateLimitation(
    period: UsageInsightsPeriodSummary
  ) -> UsageMetricLimitation? {
    if accountScope == .sharedLocalCache {
      return period.spend.limitation ?? .sharedAccountScope
    }
    return period.spend.limitation ?? period.tokens.total.limitation
  }
}

private extension UsageProvider {
  var insightsSource: UsageInsightsSource {
    switch self {
    case .codex:
      .localCodexLogs
    case .claude:
      .localClaudeCacheLogs
    }
  }

  func defaultInsightsSourceDescription(
    accountScope: UsageInsightsAccountScope
  ) -> String {
    switch (self, accountScope) {
    case (.codex, .exact):
      "Estimated from local Codex logs"
    case (.claude, .exact):
      "Estimated from local Claude cache logs"
    case (.codex, .sharedLocalCache):
      "Estimated from local Codex logs (not account-specific)"
    case (.claude, .sharedLocalCache):
      "Estimated from local Claude cache logs (not account-specific)"
    }
  }
}
