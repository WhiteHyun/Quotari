import Foundation

enum LocalCostSummaryBuilder {
  static func summary(
    provider: UsageProvider,
    records: [LocalTokenRecord],
    range: DayRange,
    pricing: LocalModelPricing
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
      sourceDescription: sourceDescription(for: provider),
      daily: daily
    )
  }

  private static func sourceDescription(for provider: UsageProvider) -> String {
    switch provider {
    case .codex:
      "Estimated from local Codex logs"
    case .claude:
      "Estimated from local Claude logs"
    case .glm:
      "Estimated from local logs"
    }
  }
}

struct LocalModelPricing {
  func costUSD(provider: UsageProvider, model: String?, tokens: TokenTotals) -> Double {
    let rates = rates(provider: provider, model: model)
    let input = Double(tokens.input) * rates.inputPerMillion / 1_000_000
    let cacheRead = Double(tokens.cacheRead) * rates.cacheReadPerMillion / 1_000_000
    let cacheWrite = Double(tokens.cacheWrite) * rates.cacheWritePerMillion / 1_000_000
    let output = Double(tokens.output) * rates.outputPerMillion / 1_000_000
    return input + cacheRead + cacheWrite + output
  }

  private func rates(provider: UsageProvider, model: String?) -> Rates {
    let normalized = model?.lowercased() ?? ""
    switch provider {
    case .codex:
      if normalized.contains("mini") { return Rates(input: 0.25, cacheRead: 0.025, output: 2.00) }
      if normalized.contains("nano") { return Rates(input: 0.05, cacheRead: 0.005, output: 0.40) }
      return Rates(input: 1.25, cacheRead: 0.125, output: 10.00)
    case .claude:
      if normalized.contains("opus") { return Rates(input: 15.00, cacheRead: 1.50, output: 75.00) }
      if normalized.contains("haiku") { return Rates(input: 0.80, cacheRead: 0.08, output: 4.00) }
      return Rates(input: 3.00, cacheRead: 0.30, output: 15.00)
    case .glm:
      return Rates(input: 0, cacheRead: 0, output: 0)
    }
  }

  private struct Rates {
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
