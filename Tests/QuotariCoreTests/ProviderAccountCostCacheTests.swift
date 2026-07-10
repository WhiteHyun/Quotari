import Foundation
@testable import QuotariCore
import Testing

struct ProviderAccountCostCacheTests {
  @Test func reauthenticationAtSameCredentialSourceDoesNotReuseCache() throws {
    let now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-account-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAccount = Self.account(name: "First", identity: "first-account")
    let replacementAccount = Self.account(name: "Replacement", identity: "replacement-account")
    let summary = Self.summary(endingAt: now)
    LocalUsageCostCache(cacheDirectory: directory).save(
      summary,
      provider: .codex,
      scopeID: firstAccount.costCacheScopeID,
      now: now,
      historyDays: 30
    )
    let estimator = LocalUsageCostEstimator.testing(
      environment: [:],
      homeDirectory: directory,
      cacheDirectory: directory
    )

    #expect(firstAccount.id == replacementAccount.id)
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: firstAccount,
      now: now,
      historyDays: 30
    ) == summary)
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: replacementAccount,
      now: now,
      historyDays: 30
    ) == nil)
  }

  private static func account(name: String, identity: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: name,
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json"),
      credentialIdentity: identity
    )
  }

  private static func summary(endingAt now: Date) -> CostSummary {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: now)
    let daily = (0 ..< 30).compactMap { offset -> DailyCost? in
      guard let date = calendar.date(byAdding: .day, value: offset - 29, to: today) else { return nil }
      return DailyCost(date: date, spend: offset == 29 ? 1 : 0, tokens: offset == 29 ? 100 : 0)
    }
    return CostSummary(todaySpend: 1, monthSpend: 1, monthTokens: 100, latestTokens: 100, daily: daily)
  }
}
