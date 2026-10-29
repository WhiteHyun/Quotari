import Foundation

/// Daily usage as CSV or JSON. Every row says where its numbers came from and
/// how much of its spend is priced; session fingerprints stay out.
public struct UsageExport: Sendable {
  public enum Format: String, CaseIterable, Sendable {
    case csv
    case json
  }

  public var provider: UsageProvider
  public var source: UsageInsightsSource
  public var accountScope: UsageInsightsAccountScope
  public var days: [DailyUsageInsight]

  public init(
    provider: UsageProvider,
    source: UsageInsightsSource,
    accountScope: UsageInsightsAccountScope,
    days: [DailyUsageInsight]
  ) {
    self.provider = provider
    self.source = source
    self.accountScope = accountScope
    self.days = days
  }

  public func data(_ format: Format, exportedAt: Date, calendar: Calendar = .current) throws -> Data {
    switch format {
    case .csv: Data(csv(calendar: calendar).utf8)
    case .json: try json(exportedAt: exportedAt, calendar: calendar)
    }
  }

  static let csvHeader = [
    "date", "provider", "source", "account_scope", "spend_usd", "spend_status",
    "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "total_tokens",
    "sessions", "priced_tokens", "unpriced_tokens", "unpriced_models", "stale_pricing", "models",
  ]

  /// One row per day.
  public func csv(calendar: Calendar = .current) -> String {
    let formatter = Self.dayFormatter(calendar: calendar)
    let rows = days.map { day in
      [
        formatter.string(from: day.date),
        provider.rawValue,
        source.rawValue,
        accountScope.rawValue,
        day.spend.value.map(Self.dollars) ?? "",
        Self.status(day.spend.availability),
        Self.count(day.tokens.input),
        Self.count(day.tokens.output),
        Self.count(day.tokens.cacheRead),
        Self.count(day.tokens.cacheWrite),
        Self.count(day.tokens.total),
        Self.count(day.sessionCount),
        String(day.pricingCoverage.pricedTokens),
        String(day.pricingCoverage.unpricedTokens),
        day.pricingCoverage.unpricedModels.joined(separator: ";"),
        String(day.pricingCoverage.usesStalePricing),
        day.models.map(\.modelID).joined(separator: ";"),
      ]
    }
    return ([Self.csvHeader] + rows)
      .map { $0.map(Self.escaped).joined(separator: ",") }
      .joined(separator: "\n") + "\n"
  }

  /// The days with their per-model breakdown.
  public func json(exportedAt: Date, calendar: Calendar = .current) throws -> Data {
    let formatter = Self.dayFormatter(calendar: calendar)
    let document = Document(
      exportedAt: exportedAt,
      provider: provider.rawValue,
      source: source.rawValue,
      accountScope: accountScope.rawValue,
      days: days.map { day in
        Document.Day(
          date: formatter.string(from: day.date),
          spendUSD: day.spend.value,
          spendStatus: Self.status(day.spend.availability),
          tokens: Document.Tokens(day.tokens),
          sessions: day.sessionCount.value,
          pricingCoverage: Document.Coverage(day.pricingCoverage),
          models: day.models.map { model in
            Document.Model(
              model: model.modelID,
              spendUSD: model.spend.value,
              spendStatus: Self.status(model.spend.availability),
              tokens: Document.Tokens(model.tokens),
              pricingCoverage: Document.Coverage(model.pricingCoverage)
            )
          }
        )
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(document)
  }

  private static func dayFormatter(calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  private static func dollars(_ value: Double) -> String {
    String(format: "%.4f", value)
  }

  private static func count(_ metric: UsageMetric<Int>) -> String {
    metric.value.map(String.init) ?? ""
  }

  static func status(_ availability: UsageMetricAvailability) -> String {
    switch availability {
    case .available: "available"
    case let .partial(limitation): "partial:\(limitation.rawValue)"
    case let .unavailable(limitation): "unavailable:\(limitation.rawValue)"
    }
  }

  private static func escaped(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

private struct Document: Encodable {
  struct Tokens: Encodable {
    var input, output, cacheRead, cacheWrite, total: Int?

    init(_ tokens: UsageTokenBreakdown) {
      input = tokens.input.value
      output = tokens.output.value
      cacheRead = tokens.cacheRead.value
      cacheWrite = tokens.cacheWrite.value
      total = tokens.total.value
    }
  }

  struct Coverage: Encodable {
    var pricedTokens: Int
    var unpricedTokens: Int
    var unpricedModels: [String]
    var usesStalePricing: Bool

    init(_ coverage: CostEstimateCoverage) {
      pricedTokens = coverage.pricedTokens
      unpricedTokens = coverage.unpricedTokens
      unpricedModels = coverage.unpricedModels
      usesStalePricing = coverage.usesStalePricing
    }
  }

  struct Model: Encodable {
    var model: String
    var spendUSD: Double?
    var spendStatus: String
    var tokens: Tokens
    var pricingCoverage: Coverage
  }

  struct Day: Encodable {
    var date: String
    var spendUSD: Double?
    var spendStatus: String
    var tokens: Tokens
    var sessions: Int?
    var pricingCoverage: Coverage
    var models: [Model]
  }

  var schemaVersion = 1
  var exportedAt: Date
  var provider: String
  var source: String
  var accountScope: String
  var days: [Day]
}
