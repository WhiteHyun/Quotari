import Foundation

enum LocalCostSummaryBuilder {
  static func summary(
    provider: UsageProvider,
    records: [LocalTokenRecord],
    range: DayRange,
    pricing: LocalModelPricing,
    sourceDescription: String? = nil
  ) -> CostSummary? {
    guard !records.isEmpty else { return nil }

    let aggregation = aggregate(provider: provider, records: records, pricing: pricing)

    let daily = range.days.map { day in
      let totals = aggregation.dayTotals[day] ?? (0, 0)
      return DailyCost(date: day, spend: totals.spend, tokens: totals.tokens)
    }
    let monthSpend = daily.reduce(0) { $0 + $1.spend }
    let monthTokens = daily.reduce(0) { $0 + $1.tokens }
    guard monthSpend > 0 || monthTokens > 0 else { return nil }

    let topModel = aggregation.modelTotals.max { lhs, rhs in
      if lhs.value.spend != rhs.value.spend {
        return lhs.value.spend < rhs.value.spend
      }
      return lhs.value.tokens < rhs.value.tokens
    }?.key

    return CostSummary(
      todaySpend: daily.last?.spend ?? 0,
      monthSpend: monthSpend,
      monthTokens: monthTokens,
      latestTokens: daily.last(where: { $0.tokens > 0 })?.tokens ?? 0,
      topModel: topModel,
      sourceDescription: sourceDescription ?? Self.sourceDescription(for: provider),
      estimateCoverage: CostEstimateCoverage(
        pricedTokens: aggregation.pricedTokens,
        unpricedTokens: aggregation.unpricedTokens,
        unpricedModels: aggregation.unpricedModels.sorted(),
        usesStalePricing: aggregation.usesStalePricing
      ),
      daily: daily
    )
  }

  private static func sourceDescription(for provider: UsageProvider) -> String {
    switch provider {
    case .codex:
      "Estimated from local Codex logs"
    case .claude:
      "Estimated from local Claude cache logs"
    }
  }

  private static func aggregate(
    provider: UsageProvider,
    records: [LocalTokenRecord],
    pricing: LocalModelPricing
  ) -> LocalCostAggregation {
    var aggregation = LocalCostAggregation()
    for record in records {
      let priced = pricing.price(
        provider: provider,
        model: record.model,
        tokens: record.tokens,
        contextInputTokens: record.contextInputTokens
      )
      aggregation.add(record: record, priced: priced)
    }
    return aggregation
  }
}

private struct LocalCostAggregation {
  var dayTotals: [Date: (spend: Double, tokens: Int)] = [:]
  var modelTotals: [String: (spend: Double, tokens: Int)] = [:]
  var pricedTokens = 0
  var unpricedTokens = 0
  var unpricedModels = Set<String>()
  var usesStalePricing = false

  mutating func add(record: LocalTokenRecord, priced: LocalPricingResult) {
    var day = dayTotals[record.day, default: (0, 0)]
    day.spend += priced.spend
    day.tokens += record.tokens.total
    dayTotals[record.day] = day
    pricedTokens += priced.pricedTokens
    unpricedTokens += priced.unpricedTokens
    usesStalePricing = usesStalePricing || priced.usesStalePricing
    if priced.unpricedTokens > 0 {
      unpricedModels.insert(record.model.map(normalizedModelID) ?? "Unknown model")
    }
    if let modelName = record.model {
      var model = modelTotals[modelName, default: (0, 0)]
      model.spend += priced.spend
      model.tokens += record.tokens.total
      modelTotals[modelName] = model
    }
  }
}

struct LocalModelPricing {
  let snapshot: ModelPricingCatalogSnapshot

  init(snapshot: ModelPricingCatalogSnapshot = .bundledOnly) {
    self.snapshot = snapshot
  }

  func costUSD(provider: UsageProvider, model: String?, tokens: TokenTotals) -> Double {
    price(provider: provider, model: model, tokens: tokens, contextInputTokens: nil).spend
  }

  func price(
    provider: UsageProvider,
    model: String?,
    tokens: TokenTotals,
    contextInputTokens: Int?
  ) -> LocalPricingResult {
    let key = model.map { ModelPricingKey(provider: provider, modelID: $0) }
    guard let key else {
      return .unpriced(tokens: tokens.total)
    }
    let remote = snapshot.remote.pricing(for: key)
    let bundled = BundledModelPricingCatalog.pricing(for: key)
    guard let pricing = remote?.fillingMissing(with: bundled) ?? bundled else {
      return .unpriced(tokens: tokens.total)
    }

    let inferredContextTokens = contextInputTokens
      ?? (tokens.input + tokens.cacheRead + tokens.cacheWrite)
    let rates = pricing.rates(contextInputTokens: inferredContextTokens)
    var spend = 0.0
    var pricedTokens = 0
    var unpricedTokens = 0
    add(tokens.input, rate: rates.inputPerMillion, spend: &spend, priced: &pricedTokens, unpriced: &unpricedTokens)
    add(
      tokens.cacheRead,
      rate: rates.cacheReadPerMillion,
      spend: &spend,
      priced: &pricedTokens,
      unpriced: &unpricedTokens
    )
    add(
      tokens.cacheWrite,
      rate: rates.cacheWritePerMillion,
      spend: &spend,
      priced: &pricedTokens,
      unpriced: &unpricedTokens
    )
    add(
      tokens.output,
      rate: rates.outputPerMillion,
      spend: &spend,
      priced: &pricedTokens,
      unpriced: &unpricedTokens
    )
    return LocalPricingResult(
      spend: spend,
      pricedTokens: pricedTokens,
      unpricedTokens: unpricedTokens,
      usesStalePricing: remote != nil && snapshot.remoteIsStale
    )
  }

  private func add(
    _ tokens: Int,
    rate: Double?,
    spend: inout Double,
    priced: inout Int,
    unpriced: inout Int
  ) {
    guard tokens > 0 else { return }
    guard let rate else {
      unpriced += tokens
      return
    }
    spend += Double(tokens) * rate / 1_000_000
    priced += tokens
  }
}

struct LocalPricingResult: Equatable, Sendable {
  let spend: Double
  let pricedTokens: Int
  let unpricedTokens: Int
  let usesStalePricing: Bool

  static func unpriced(tokens: Int) -> Self {
    Self(spend: 0, pricedTokens: 0, unpricedTokens: tokens, usesStalePricing: false)
  }
}

enum BundledModelPricingCatalog {
  private static let codexRules: [BundledPricingRule] = [
    .exact("gpt-5.6-sol", pricing: pricing(5, 0.5, 6.25, 30, long: rates(10, 1, 12.5, 45))),
    .exact("gpt-5.6-terra", pricing: pricing(2.5, 0.25, 3.125, 15, long: rates(5, 0.5, 6.25, 22.5))),
    .exact("gpt-5.6-luna", pricing: pricing(1, 0.1, 1.25, 6, long: rates(2, 0.2, 2.5, 9))),
    .exact("gpt-5.5", pricing: pricing(5, 0.5, 6.25, 30)),
    .exact("gpt-5.4-mini", pricing: pricing(0.75, 0.075, 0.9375, 4.5)),
    .exact("gpt-5.4-nano", pricing: pricing(0.2, 0.02, 0.25, 1.25)),
    .exact("gpt-5.4", pricing: pricing(2.5, 0.25, 3.125, 15)),
    .exact("gpt-5.3-codex", pricing: pricing(1.75, 0.175, 2.1875, 14)),
    .exact("gpt-5.2", pricing: pricing(1.75, 0.175, 2.1875, 14)),
    .exact("gpt-5", pricing: pricing(1.25, 0.125, 1.5625, 10)),
  ]

  private static let claudeRules: [BundledPricingRule] = [
    .exactOrDated("claude-fable-5", pricing: pricing(10, 1, 12.5, 50)),
    .exactOrDated("claude-opus-4-8", pricing: pricing(5, 0.5, 6.25, 25)),
    .exactOrDated("claude-opus-4-7", pricing: pricing(5, 0.5, 6.25, 25)),
    .exactOrDated("claude-opus-4-6", pricing: pricing(5, 0.5, 6.25, 25)),
    .exactOrDated("claude-opus-4-5", pricing: pricing(5, 0.5, 6.25, 25)),
    .exactOrDated("claude-opus-4-1", pricing: pricing(15, 1.5, 18.75, 75)),
    .exactOrDated("claude-opus-4", pricing: pricing(15, 1.5, 18.75, 75)),
    .exactOrDated("claude-haiku-4-5", pricing: pricing(1, 0.1, 1.25, 5)),
    .exactOrDated("claude-sonnet-5", pricing: pricing(2, 0.2, 2.5, 10)),
    .exactOrDated("claude-sonnet-4-6", pricing: pricing(3, 0.3, 3.75, 15)),
    .exactOrDated("claude-sonnet-4-5", pricing: pricing(3, 0.3, 3.75, 15)),
    .exactOrDated("claude-sonnet-4", pricing: pricing(3, 0.3, 3.75, 15)),
  ]

  static func pricing(for key: ModelPricingKey) -> ModelPricing? {
    let rules: [BundledPricingRule] = switch key.provider {
    case .codex: codexRules
    case .claude: claudeRules
    }
    return rules.first { $0.matches(key.modelID) }?.pricing
  }

  private static func pricing(
    _ input: Double,
    _ cacheRead: Double,
    _ cacheWrite: Double,
    _ output: Double,
    long: ModelRateComponents? = nil
  ) -> ModelPricing {
    let longContext = long.map { rates in
      LongContextModelPricing(
        thresholdTokens: 272_000,
        overrides: rates
      )
    }
    return ModelPricing(
      standard: ModelRateComponents(
        input: input,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        output: output
      ),
      longContext: longContext
    )
  }

  private static func rates(
    _ input: Double,
    _ cacheRead: Double,
    _ cacheWrite: Double,
    _ output: Double
  ) -> ModelRateComponents {
    ModelRateComponents(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
  }
}

private struct BundledPricingRule {
  let modelID: String
  let acceptsDatedSuffix: Bool
  let pricing: ModelPricing

  static func exact(_ modelID: String, pricing: ModelPricing) -> Self {
    Self(modelID: modelID, acceptsDatedSuffix: false, pricing: pricing)
  }

  static func exactOrDated(_ modelID: String, pricing: ModelPricing) -> Self {
    Self(modelID: modelID, acceptsDatedSuffix: true, pricing: pricing)
  }

  func matches(_ model: String) -> Bool {
    model == modelID || (acceptsDatedSuffix && model.datedSuffix(after: modelID) != nil)
  }
}

private extension String {
  func datedSuffix(after modelID: String) -> String? {
    let prefix = "\(modelID)-"
    guard hasPrefix(prefix) else { return nil }
    let suffix = dropFirst(prefix.count)
    guard suffix.count == 8,
          suffix.allSatisfy(\.isNumber)
    else { return nil }
    return String(suffix)
  }
}

struct DayRange: Sendable {
  let start: Date
  let end: Date
  let calendar: Calendar
  let days: [Date]

  init(start: Date, end: Date, calendar: Calendar) {
    self.start = calendar.startOfDay(for: start)
    self.end = calendar.startOfDay(for: end)
    self.calendar = calendar
    var days: [Date] = []
    var cursor = self.start
    while cursor <= self.end {
      days.append(cursor)
      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
      cursor = next
    }
    self.days = days
  }

  func day(containing date: Date) -> Date? {
    let day = calendar.startOfDay(for: date)
    guard day >= start, day <= end else { return nil }
    return day
  }
}

struct LocalTokenRecord: Sendable {
  let day: Date
  let model: String?
  let tokens: TokenTotals
  let contextInputTokens: Int?

  init(day: Date, model: String?, tokens: TokenTotals, contextInputTokens: Int? = nil) {
    self.day = day
    self.model = model
    self.tokens = tokens
    self.contextInputTokens = contextInputTokens
  }
}

struct TokenTotals: Sendable {
  let input: Int
  let cacheRead: Int
  let cacheWrite: Int
  let output: Int

  var total: Int {
    input + cacheRead + cacheWrite + output
  }

  func delta(from previous: TokenTotals?) -> TokenTotals {
    let previous = previous ?? TokenTotals(input: 0, cacheRead: 0, cacheWrite: 0, output: 0)
    return TokenTotals(
      input: max(0, input - previous.input),
      cacheRead: max(0, cacheRead - previous.cacheRead),
      cacheWrite: max(0, cacheWrite - previous.cacheWrite),
      output: max(0, output - previous.output)
    )
  }
}
