import Foundation
@testable import QuotariCore
import Testing

struct RegistryTests {
  @Test func supportsOnlyLiveProviderFamilies() {
    #expect(UsageProvider.allCases == [.codex, .claude])
  }

  @Test func everyProviderHasADescriptor() {
    #expect(ProviderRegistry.isComplete)
    for provider in UsageProvider.allCases {
      #expect(ProviderRegistry.descriptor(for: provider).id == provider)
    }
  }

  @Test func mockPipelineReturnsUsage() async throws {
    // Exercise the mock strategy directly so the result doesn't depend on
    // whether real credentials happen to exist in the test environment.
    let value = try await MockProviders.codexStrategy
      .fetch(ProviderFetchContext(provider: .codex, now: Date()))
    #expect(value.usage.primary?.usedPercent == 73)
    #expect(value.usage.plan == "Pro 5x")
    #expect(!value.usage.extraWindows.isEmpty)
    #expect(value.sourceLabel == "Mock")
  }
}

struct UsagePaceTests {
  @Test func deficitWhenAheadOfLinearPace() {
    let now = Date()
    // 73% used with ~65% of the window elapsed → ahead of pace (deficit).
    let window = RateWindow(
      kind: .session,
      usedPercent: 73,
      resetsAt: now.addingTimeInterval(104 * 60),
      duration: 300 * 60
    )
    let pace = try? #require(UsagePace.compute(window: window, now: now))
    #expect(pace?.isDeficit == true)
    #expect((pace?.runsOutIn ?? .greatestFiniteMagnitude) < 104 * 60)
  }

  @Test func reserveWhenBehindLinearPace() {
    let now = Date()
    // 32% used with ~26% elapsed → slightly ahead here; use a clearly-behind case.
    let window = RateWindow(
      kind: .weekly,
      usedPercent: 10,
      resetsAt: now.addingTimeInterval(24 * 3600),
      duration: 7 * 24 * 3600
    )
    let pace = UsagePace.compute(window: window, now: now)
    #expect(pace?.isDeficit == false)
    #expect(pace?.runsOutIn == nil) // lasts until reset
  }
}

struct FormatterTests {
  @Test func percentHandlesSubOnePercent() {
    #expect(UsageFormatter.percent(0.4) == "<1%")
    #expect(UsageFormatter.percent(82) == "82%")
    #expect(UsageFormatter.percent(0) == "0%")
  }

  @Test func resetCountdownFormats() {
    let now = Date()
    #expect(UsageFormatter.resetCountdown(to: nil, now: now) == nil)
    #expect(UsageFormatter.resetCountdown(to: now.addingTimeInterval(-10), now: now) == "now")
    let future = now.addingTimeInterval(3 * 3600 + 5 * 60)
    #expect(UsageFormatter.resetCountdown(to: future, now: now)?.hasPrefix("in 3h") == true)
  }

  @Test func currencyAndTokens() {
    #expect(UsageFormatter.currency(30.47) == "$30.47")
    #expect(UsageFormatter.tokens(952_000_000) == "952M")
    #expect(UsageFormatter.tokens(32000) == "32K")
    #expect(UsageFormatter.tokens(1_200_000_000) == "1.2B")
    #expect(UsageFormatter.tokens(500) == "500")
  }
}

struct CostTests {
  @Test func mockCostSummaryIsPopulated() async throws {
    let result = try await MockProviders.codexStrategy
      .fetch(ProviderFetchContext(provider: .codex, now: Date()))
    let cost = try #require(result.usage.cost)
    #expect(cost.daily.count == 30)
    #expect(cost.monthSpend > 0)
    #expect(cost.peakSpend >= cost.todaySpend)
    #expect(cost.topModel == "gpt-5.5")
  }
}
