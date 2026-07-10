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

    var dayTotals: [Date: (spend: Double, tokens: Int)] = [:]
    var modelTotals: [String: (spend: Double, tokens: Int)] = [:]
    for record in records {
      let spend = pricing.costUSD(provider: provider, model: record.model, tokens: record.tokens)
      var day = dayTotals[record.day, default: (0, 0)]
      day.spend += spend
      day.tokens += record.tokens.total
      dayTotals[record.day] = day

      if let modelName = record.model {
        var model = modelTotals[modelName, default: (0, 0)]
        model.spend += spend
        model.tokens += record.tokens.total
        modelTotals[modelName] = model
      }
    }

    let daily = range.days.map { day in
      let totals = dayTotals[day] ?? (0, 0)
      return DailyCost(date: day, spend: totals.spend, tokens: totals.tokens)
    }
    let monthSpend = daily.reduce(0) { $0 + $1.spend }
    let monthTokens = daily.reduce(0) { $0 + $1.tokens }
    guard monthSpend > 0 || monthTokens > 0 else { return nil }

    let topModel = modelTotals.max { lhs, rhs in
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
      daily: daily
    )
  }

  private static func sourceDescription(for provider: UsageProvider) -> String {
    switch provider {
    case .codex:
      "Estimated from local Codex logs"
    case .claude:
      "Estimated from local Claude cache logs"
    case .glm:
      "Estimated from local logs"
    }
  }
}

struct LocalModelPricing {
  func costUSD(provider: UsageProvider, model: String?, tokens: TokenTotals) -> Double {
    let rates = ModelPricingCatalog.rates(provider: provider, model: model)
    let input = Double(tokens.input) * rates.inputPerMillion / 1_000_000
    let cacheRead = Double(tokens.cacheRead) * rates.cacheReadPerMillion / 1_000_000
    let cacheWrite = Double(tokens.cacheWrite) * rates.cacheWritePerMillion / 1_000_000
    let output = Double(tokens.output) * rates.outputPerMillion / 1_000_000
    return input + cacheRead + cacheWrite + output
  }
}

private enum ModelPricingCatalog {
  private static let codexRules: [ModelPricingRule] = [
    .exact("gpt-5.5", rates: .init(input: 5.00, cacheRead: 0.50, output: 30.00)),
    .exact("gpt-5.4-mini", rates: .init(input: 0.75, cacheRead: 0.075, output: 4.50)),
    .exact("gpt-5.4-nano", rates: .init(input: 0.20, cacheRead: 0.02, output: 1.25)),
    .exact("gpt-5.4", rates: .init(input: 2.50, cacheRead: 0.25, output: 15.00)),
    .exact("gpt-5.3-codex", rates: .init(input: 1.75, cacheRead: 0.175, output: 14.00)),
  ]

  private static let claudeRules: [ModelPricingRule] = [
    .exactOrDated("claude-fable-5", rates: .init(input: 10.00, cacheRead: 1.00, output: 50.00)),
    .exactOrDated("claude-opus-4-8", rates: .init(input: 5.00, cacheRead: 0.50, output: 25.00)),
    .exactOrDated("claude-opus-4-7", rates: .init(input: 5.00, cacheRead: 0.50, output: 25.00)),
    .exactOrDated("claude-opus-4-6", rates: .init(input: 5.00, cacheRead: 0.50, output: 25.00)),
    .exactOrDated("claude-opus-4-5", rates: .init(input: 5.00, cacheRead: 0.50, output: 25.00)),
    .exactOrDated("claude-haiku-4-5", rates: .init(input: 1.00, cacheRead: 0.10, output: 5.00)),
    .exactOrDated("claude-sonnet-5", rates: .init(input: 3.00, cacheRead: 0.30, output: 15.00)),
  ]

  static func rates(provider: UsageProvider, model: String?) -> ModelRates {
    let normalized = normalizedModelID(model)
    switch provider {
    case .codex:
      return codexRules.first { $0.matches(normalized) }?.rates
        ?? .init(input: 1.25, cacheRead: 0.125, output: 10.00)
    case .claude:
      return claudeRules.first { $0.matches(normalized) }?.rates
        ?? legacyClaudeRates(model: normalized)
    case .glm:
      return .init(input: 0, cacheRead: 0, output: 0)
    }
  }

  private static func legacyClaudeRates(model: String) -> ModelRates {
    if model.contains("-opus-") {
      return .init(input: 15.00, cacheRead: 1.50, output: 75.00)
    }
    if model.contains("-haiku-") {
      return .init(input: 0.80, cacheRead: 0.08, output: 4.00)
    }
    return .init(input: 3.00, cacheRead: 0.30, output: 15.00)
  }
}

private struct ModelPricingRule {
  let matcher: ModelMatcher
  let rates: ModelRates

  static func exact(_ modelID: String, rates: ModelRates) -> ModelPricingRule {
    ModelPricingRule(matcher: .exact(modelID), rates: rates)
  }

  static func exactOrDated(_ modelID: String, rates: ModelRates) -> ModelPricingRule {
    ModelPricingRule(matcher: .exactOrDated(modelID), rates: rates)
  }

  func matches(_ model: String) -> Bool {
    matcher.matches(model)
  }
}

private enum ModelMatcher {
  case exact(String)
  case exactOrDated(String)

  func matches(_ model: String) -> Bool {
    switch self {
    case let .exact(modelID):
      model == modelID
    case let .exactOrDated(modelID):
      model == modelID || model.datedSuffix(after: modelID) != nil
    }
  }
}

private struct ModelRates {
  let inputPerMillion: Double
  let cacheReadPerMillion: Double
  let cacheWritePerMillion: Double
  let outputPerMillion: Double

  init(input: Double, cacheRead: Double, cacheWrite: Double? = nil, output: Double) {
    inputPerMillion = input
    cacheReadPerMillion = cacheRead
    cacheWritePerMillion = cacheWrite ?? input * 1.25
    outputPerMillion = output
  }
}

private func normalizedModelID(_ model: String?) -> String {
  model?
    .lowercased()
    .replacingOccurrences(of: "_", with: "-") ?? ""
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

struct DayRange {
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

struct LocalTokenRecord {
  let day: Date
  let model: String?
  let tokens: TokenTotals
}

struct TokenTotals {
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
