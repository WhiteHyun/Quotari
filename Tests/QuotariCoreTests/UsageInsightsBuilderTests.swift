import CustomDump
import Foundation
@testable import QuotariCore
import Testing

struct UsageInsightsBuilderTests {
  @Test func slicesThirtyDaysIntoAConsistentSevenDayPeriod() throws {
    let fixture = try Self.fixture(provider: .codex)
    let summary = try #require(LocalUsageInsightsBuilder.summary(.init(
      provider: .codex,
      records: [
        LocalTokenRecord(
          day: fixture.range.days[0],
          model: "gpt-5.4",
          tokens: TokenTotals(input: 1000, cacheRead: 0, cacheWrite: 0, output: 0),
          sessionID: "old-session"
        ),
        LocalTokenRecord(
          day: fixture.range.days[29],
          model: "gpt-5",
          tokens: TokenTotals(input: 100, cacheRead: 100, cacheWrite: 0, output: 50),
          sessionID: "current-session"
        ),
      ],
      range: fixture.range,
      pricing: LocalModelPricing(),
      scopeKey: fixture.scopeKey,
      accountScope: .exact,
      generatedAt: fixture.now
    )))

    let sevenDays = try #require(summary.period(.sevenDays))
    let thirtyDays = try #require(summary.period(.thirtyDays))

    #expect(sevenDays.daily.count == 7)
    expectNoDifference(
      sevenDays.tokens,
      UsageTokenBreakdown(
        input: .available(100),
        output: .available(50),
        cacheRead: .available(100),
        cacheWrite: .available(0),
        total: .available(250)
      )
    )
    expectNoDifference(sevenDays.sessionCount, .available(1))
    expectNoDifference(sevenDays.cacheEfficiency, .available(0.5))
    expectNoDifference(sevenDays.topModel?.modelID, "gpt-5")
    expectNoDifference(thirtyDays.tokens.total, .available(1250))
    expectNoDifference(thirtyDays.sessionCount, .available(2))
  }

  @Test func unavailablePricingKeepsTrustworthyTokenFallback() throws {
    let fixture = try Self.fixture(provider: .codex, historyDays: 1)
    let summary = try #require(LocalUsageInsightsBuilder.summary(.init(
      provider: .codex,
      records: [
        LocalTokenRecord(
          day: fixture.range.end,
          model: "future-gpt",
          tokens: TokenTotals(input: 100, cacheRead: 0, cacheWrite: 0, output: 20),
          sessionID: "session"
        ),
      ],
      range: fixture.range,
      pricing: LocalModelPricing(),
      scopeKey: fixture.scopeKey,
      accountScope: .exact,
      generatedAt: fixture.now
    )))
    let period = try #require(summary.period(days: 1))

    expectNoDifference(period.spend, .unavailable(.missingPricing))
    expectNoDifference(period.tokens.total, .available(120))
    expectNoDifference(
      period.pricingCoverage,
      CostEstimateCoverage(
        pricedTokens: 0,
        unpricedTokens: 120,
        unpricedModels: ["future-gpt"]
      )
    )
    #expect(summary.costSummary?.estimateCoverage?.availability == .unavailable)
    #expect(summary.costSummary?.monthTokens == 120)
  }

  @Test func claudePlaceholderFieldsRemainUnavailable() throws {
    let fixture = try Self.fixture(provider: .claude, historyDays: 1)
    let summary = try #require(LocalUsageInsightsBuilder.summary(.init(
      provider: .claude,
      records: [
        LocalTokenRecord(
          day: fixture.range.end,
          model: "claude-sonnet-4",
          tokens: TokenTotals(input: 0, cacheRead: 80, cacheWrite: 20, output: 0),
          sessionID: "session"
        ),
      ],
      range: fixture.range,
      pricing: LocalModelPricing(),
      scopeKey: fixture.scopeKey,
      accountScope: .sharedLocalCache,
      generatedAt: fixture.now
    )))
    let period = try #require(summary.period(days: 1))

    expectNoDifference(period.tokens.input, .unavailable(.unsupportedTokenFields))
    expectNoDifference(period.tokens.output, .unavailable(.unsupportedTokenFields))
    expectNoDifference(period.tokens.cacheRead, .available(80))
    expectNoDifference(
      period.tokens.total,
      .partial(value: 100, limitation: .unsupportedTokenFields)
    )
    expectNoDifference(period.cacheEfficiency, .unavailable(.unsupportedTokenFields))
    expectNoDifference(
      period.spend.availability,
      .partial(.unsupportedTokenFields)
    )
  }

  @Test func topModelUsesModelIDForDeterministicTokenTies() throws {
    let fixture = try Self.fixture(provider: .codex, historyDays: 1)
    let summary = try #require(LocalUsageInsightsBuilder.summary(.init(
      provider: .codex,
      records: [
        LocalTokenRecord(
          day: fixture.range.end,
          model: "zeta-model",
          tokens: TokenTotals(input: 100, cacheRead: 0, cacheWrite: 0, output: 0)
        ),
        LocalTokenRecord(
          day: fixture.range.end,
          model: "alpha-model",
          tokens: TokenTotals(input: 100, cacheRead: 0, cacheWrite: 0, output: 0)
        ),
      ],
      range: fixture.range,
      pricing: LocalModelPricing(),
      scopeKey: fixture.scopeKey,
      accountScope: .exact,
      generatedAt: fixture.now
    )))

    expectNoDifference(summary.period(days: 1)?.topModel?.modelID, "alpha-model")
  }

  private static func fixture(
    provider: UsageProvider,
    historyDays: Int = 30
  ) throws -> BuilderFixture {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(calendar.date(from: DateComponents(
      year: 2026,
      month: 7,
      day: 8,
      hour: 12
    )))
    let today = calendar.startOfDay(for: now)
    let start = try #require(calendar.date(byAdding: .day, value: -(historyDays - 1), to: today))
    return BuilderFixture(
      now: now,
      range: DayRange(start: start, end: today, calendar: calendar),
      scopeKey: UsageInsightsScopeKey(provider: provider, accountScopeID: "test-scope")
    )
  }
}

private struct BuilderFixture {
  var now: Date
  var range: DayRange
  var scopeKey: UsageInsightsScopeKey
}
