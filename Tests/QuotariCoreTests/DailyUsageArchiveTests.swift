import Foundation
@testable import QuotariCore
import Testing

struct DailyUsageArchiveTests {
  private static let day: TimeInterval = 86400
  private let start = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 / 86400 * 86400))
  private let scope = UsageInsightsScopeKey(provider: .claude, accountScopeID: "exact:work")

  @Test func aDayOutlivesTheLogsBehindIt() {
    var archive = DailyUsageArchive()
    archive.record(summary(tokensByDay: [0: 500, 1: 200], generatedAt: 1))

    // Claude Code deleted the logs behind day 0; its fresh summary shows nothing.
    let afterCleanup = summary(tokensByDay: [0: 0, 1: 200, 2: 50], generatedAt: 2)
    archive.record(afterCleanup)

    #expect(archive.restoring(afterCleanup).daily.map(\.totalTokens) == [500, 200, 50])
    #expect(archive.days(for: scope).map(\.totalTokens) == [500, 200, 50])
  }

  @Test func aPartlyDeletedDayKeepsItsLargerTotalButNewDataReplacesIt() {
    var archive = DailyUsageArchive()
    archive.record(summary(tokensByDay: [0: 500], generatedAt: 1))

    let shrank = archive.record(summary(tokensByDay: [0: 300], generatedAt: 2))
    let grew = archive.record(summary(tokensByDay: [0: 600], generatedAt: 2))

    #expect(!shrank)
    #expect(grew)
    #expect(archive.days(for: scope).map(\.totalTokens) == [600])
  }

  @Test func scopesStaySeparateAndOldDaysExpire() {
    var archive = DailyUsageArchive()
    archive.record(summary(tokensByDay: [0: 500], generatedAt: 1))
    let other = UsageInsightsScopeKey(provider: .claude, accountScopeID: "exact:side")

    var later = summary(tokensByDay: [0: 0, 401: 10], generatedAt: 402)
    #expect(archive.restoring(withScope(later, other)).daily.map(\.totalTokens) == [0, 10])
    later.scopeKey = scope
    archive.record(later)

    #expect(archive.days(for: scope).map(\.totalTokens) == [10])
    #expect(archive.days(for: other).isEmpty)
  }

  @Test func theArchiveSurvivesARelaunch() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("daily-usage-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = DailyUsageArchiveStore(url: url)
    var archive = DailyUsageArchive()
    archive.record(summary(tokensByDay: [0: 500], generatedAt: 1))

    #expect(store.load() == DailyUsageArchive())
    try store.save(archive)
    #expect(store.load() == archive)
  }

  private func summary(tokensByDay: [Int: Int], generatedAt dayOffset: Int) -> UsageInsightsSummary {
    UsageInsightsSummary(
      scopeKey: scope,
      generatedAt: start.addingTimeInterval(Double(dayOffset) * Self.day),
      source: .localClaudeCacheLogs,
      accountScope: .exact,
      sourceDescription: "Estimated from local logs",
      daily: tokensByDay.keys.sorted().map { offset in
        UsageInsightFixture.day(start.addingTimeInterval(Double(offset) * Self.day), tokens: tokensByDay[offset] ?? 0)
      }
    )
  }

  private func withScope(_ summary: UsageInsightsSummary, _ key: UsageInsightsScopeKey) -> UsageInsightsSummary {
    var scoped = summary
    scoped.scopeKey = key
    return scoped
  }
}

enum UsageInsightFixture {
  static func tokens(_ total: Int) -> UsageTokenBreakdown {
    UsageTokenBreakdown(
      input: .available(total / 2),
      output: .available(total / 4),
      cacheRead: .available(total / 4),
      cacheWrite: .available(0),
      total: .available(total)
    )
  }

  static func day(
    _ date: Date,
    tokens total: Int,
    spend: UsageMetric<Double>? = nil,
    models: [ModelUsageInsight] = [],
    coverage: CostEstimateCoverage? = nil
  ) -> DailyUsageInsight {
    DailyUsageInsight(
      date: date,
      spend: spend ?? .available(Double(total) / 1000),
      tokens: tokens(total),
      sessionCount: total > 0 ? .available(1) : .unavailable(.noActivity),
      models: models,
      pricingCoverage: coverage ?? CostEstimateCoverage(pricedTokens: total, unpricedTokens: 0)
    )
  }
}
