import CustomDump
import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageInsightsCacheTests {
  @Test func roundTripsOnlyTheMatchingScopeAndCalendarWindow() throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let cache = LocalUsageInsightsCache(cacheDirectory: fixture.directory)

    cache.save(fixture.summary, now: fixture.now, historyDays: 2)

    expectNoDifference(
      cache.load(scopeKey: fixture.summary.scopeKey, now: fixture.now, historyDays: 2),
      fixture.summary
    )
    #expect(cache.load(
      scopeKey: UsageInsightsScopeKey(provider: .codex, accountScopeID: "another-scope"),
      now: fixture.now,
      historyDays: 2
    ) == nil)
    #expect(cache.load(
      scopeKey: fixture.summary.scopeKey,
      now: fixture.now.addingTimeInterval(86400),
      historyDays: 2
    ) == nil)
  }

  @Test func corruptEntriesAreRejectedAndRemoved() throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let cache = LocalUsageInsightsCache(cacheDirectory: fixture.directory)
    let url = cache.cacheURL(scopeKey: fixture.summary.scopeKey, historyDays: 2)
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: url)

    #expect(cache.load(
      scopeKey: fixture.summary.scopeKey,
      now: fixture.now,
      historyDays: 2
    ) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  private static func fixture() throws -> CacheFixture {
    try CacheFixture()
  }
}

private struct CacheFixture {
  var directory: URL
  var now: Date
  var summary: UsageInsightsSummary

  init() throws {
    let calendar = Calendar(identifier: .gregorian)
    let today = try #require(calendar.date(from: DateComponents(
      year: 2026,
      month: 7,
      day: 8
    )))
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
    now = try #require(calendar.date(byAdding: .hour, value: 12, to: today))
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-insights-cache-\(UUID().uuidString)", isDirectory: true)
    summary = Self.summary(today: today, yesterday: yesterday, now: now)
  }

  private static func summary(
    today: Date,
    yesterday: Date,
    now: Date
  ) -> UsageInsightsSummary {
    let scopeKey = UsageInsightsScopeKey(provider: .codex, accountScopeID: "exact:test")
    let tokens = (
      empty: UsageTokenBreakdown(
        input: .available(0),
        output: .available(0),
        cacheRead: .available(0),
        cacheWrite: .available(0),
        total: .available(0)
      ),
      used: UsageTokenBreakdown(
        input: .available(100),
        output: .available(20),
        cacheRead: .available(0),
        cacheWrite: .available(0),
        total: .available(120)
      )
    )
    let emptyCoverage = CostEstimateCoverage(pricedTokens: 0, unpricedTokens: 0)
    return UsageInsightsSummary(
      scopeKey: scopeKey,
      generatedAt: now,
      source: .localCodexLogs,
      accountScope: .exact,
      sourceDescription: "Estimated from local Codex logs",
      daily: [
        DailyUsageInsight(
          date: yesterday,
          spend: .available(0),
          tokens: tokens.empty,
          sessionCount: .available(0),
          models: [],
          pricingCoverage: emptyCoverage
        ),
        DailyUsageInsight(
          date: today,
          spend: .available(0.001),
          tokens: tokens.used,
          sessionCount: .available(1),
          models: [],
          pricingCoverage: CostEstimateCoverage(pricedTokens: 120, unpricedTokens: 0)
        ),
      ]
    )
  }
}
