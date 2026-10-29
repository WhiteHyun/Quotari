import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMenuBarTests {
  @Test func defaultsToTheMostConstrainedPrimaryOrSecondaryWindow() throws {
    let context = try makeStore("most-constrained")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 22, secondary: 76),
      .claude: snapshot(provider: .claude, primary: 73, secondary: 91),
    ]

    #expect(context.store.menuBarPreferences.preferences.usageSource == .mostConstrained)
    #expect(context.store.menuBarUsedPercent == 91)
    #expect(context.store.menuBarRemainingPercent == 9)
    #expect(context.store.menuBarQuotaText == nil)
    #expect(
      context.store.menuBarAnimationInterval
        == IconRenderer.animationInterval(usedPercent: 91)
    )
  }

  @Test func selectingAProviderIgnoresAMoreConstrainedProvider() throws {
    let context = try makeStore("provider-source")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 42, secondary: 68),
      .claude: snapshot(provider: .claude, primary: 95, secondary: 80),
    ]

    context.store.menuBarPreferences.setUsageSource(.provider(.codex))

    #expect(context.store.menuBarUsedPercent == 68)
    #expect(context.store.menuBarRemainingPercent == 32)
    #expect(
      context.store.menuBarAnimationInterval
        == IconRenderer.animationInterval(usedPercent: 68)
    )
  }

  @Test func missingSelectedProviderReportsLoadingWithoutRemainingText() throws {
    let context = try makeStore("missing-provider")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 95, secondary: 80),
    ]
    context.store.menuBarPreferences.setUsageSource(.provider(.claude))
    context.store.menuBarPreferences.setValueMode(.remainingQuota)

    #expect(context.store.menuBarUsedPercent == nil)
    #expect(context.store.menuBarRemainingPercent == nil)
    #expect(context.store.menuBarQuotaText == nil)
    #expect(context.store.menuBarAccessibilityLabel.localizedCaseInsensitiveContains("loading"))
    #expect(context.store.menuBarAccessibilityLabel.contains("Claude"))
  }

  @Test func emptySelectedProviderReportsLoadingWithoutFallingBack() throws {
    let context = try makeStore("empty-provider")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 95, secondary: 80),
      .claude: snapshot(provider: .claude),
    ]
    context.store.menuBarPreferences.setUsageSource(.provider(.claude))
    context.store.menuBarPreferences.setValueMode(.remainingQuota)

    #expect(context.store.menuBarUsedPercent == nil)
    #expect(context.store.menuBarRemainingPercent == nil)
    #expect(context.store.menuBarQuotaText == nil)
    #expect(context.store.menuBarAccessibilityLabel.localizedCaseInsensitiveContains("loading"))
    #expect(context.store.menuBarAccessibilityLabel.contains("Claude"))
  }

  @Test func remainingTextFollowsTheDisplayPreference() throws {
    let context = try makeStore("remaining-text")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 73, secondary: 30),
    ]

    #expect(context.store.menuBarQuotaText == nil)

    context.store.menuBarPreferences.setValueMode(.remainingQuota)
    #expect(context.store.menuBarQuotaText == "27%")

    context.store.menuBarPreferences.setValueMode(.hidden)
    #expect(context.store.menuBarQuotaText == nil)
  }

  @Test func extraOnlyUsageFallsBackToTheMostConstrainedNamedWindow() throws {
    let context = try makeStore("extra-only")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: UsageSnapshot(
        provider: .codex,
        extraWindows: [
          NamedWindow(
            title: "Codex Spark Weekly",
            window: RateWindow(kind: .custom, usedPercent: 64)
          ),
          NamedWindow(
            title: "Codex Spark 5-hour",
            window: RateWindow(kind: .custom, usedPercent: 28)
          ),
        ],
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
      ),
    ]
    context.store.menuBarPreferences.setValueMode(.remainingQuota)

    #expect(context.store.menuBarUsedPercent == 64)
    #expect(context.store.menuBarQuotaText == "36%")
    #expect(!context.store.menuBarAccessibilityLabel.localizedCaseInsensitiveContains("loading"))
  }

  @Test func accessibilityDescribesTheSelectedProvider() throws {
    let context = try makeStore("provider-accessibility")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 60, secondary: 20),
      .claude: snapshot(provider: .claude, primary: 85, secondary: 40),
    ]
    context.store.menuBarPreferences.setUsageSource(.provider(.codex))

    let label = context.store.menuBarAccessibilityLabel

    #expect(label.contains("Codex"))
    #expect(!label.contains("Claude"))
    #expect(label.contains("40 percent"))
  }

  @Test func chosenWindowAndUsedPresentationDriveTextAndAccessibility() throws {
    let context = try makeStore("session-used")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 22, secondary: 76),
    ]
    context.store.menuBarPreferences.setValueMode(.remainingQuota)
    context.store.menuBarPreferences.setQuotaWindow(.session)
    context.store.menuBarPreferences.setQuotaPresentation(.used)

    #expect(context.store.menuBarUsedPercent == 22)
    #expect(context.store.menuBarQuotaText == "↑22%")
    let label = context.store.menuBarAccessibilityLabel
    #expect(label.contains("highest used quota, session window 22 percent"))
  }

  @Test func disabledProviderSnapshotsDoNotContributeToMenuBarUsage() throws {
    let context = try makeStore("disabled-snapshot")
    defer { context.removeDefaults() }
    context.store.setProviderEnabled(.claude, enabled: false)
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 42, secondary: 68),
      .claude: snapshot(provider: .claude, primary: 95, secondary: 80),
    ]

    #expect(context.store.highestUsedPercent == 68)
    #expect(context.store.menuBarUsedPercent == 68)
  }

  @Test func allDisabledProvidersHaveAFinalAccessibilityState() throws {
    let context = try makeStore("all-disabled-accessibility")
    defer { context.removeDefaults() }
    for descriptor in context.store.providers {
      context.store.setProviderEnabled(descriptor.id, enabled: false)
    }

    #expect(context.store.menuBarUsedPercent == nil)
    #expect(context.store.menuBarAccessibilityLabel == "Quotari, no providers enabled")
  }

  @Test func todayCostWaitsForAnExplicitSourceThenShowsItsCost() throws {
    let context = try makeStore("today-cost")
    defer { context.removeDefaults() }
    context.store.usageInsightsStates[.codex] = .loaded(Self.todaySummary(spend: .available(3.84)))
    context.store.menuBarPreferences.setValueMode(.todayCost)

    #expect(context.store.menuBarValueText == nil)
    #expect(context.store.menuBarAccessibilityLabel == "Quotari, no cost source selected")

    context.store.menuBarPreferences.setCostSource(.codex)

    #expect(context.store.menuBarValueText == LocalizedUsageFormatter.currency(3.84, code: "USD"))
  }

  @Test func disablingTheCostSourceKeepsThePreferenceButShowsNoValue() throws {
    let context = try makeStore("disabled-cost-source")
    defer { context.removeDefaults() }
    context.store.usageInsightsStates[.codex] = .loaded(Self.todaySummary(spend: .available(3.84)))
    context.store.menuBarPreferences.setValueMode(.todayCost)
    context.store.menuBarPreferences.setCostSource(.codex)

    context.store.setProviderEnabled(.codex, enabled: false)

    #expect(context.store.menuBarPreferences.preferences.costSource == .codex)
    #expect(context.store.menuBarValueText == nil)
  }

  private static func todaySummary(spend: UsageMetric<Double>) -> UsageInsightsSummary {
    let today = Calendar.current.startOfDay(for: Date())
    let tokens = UsageTokenBreakdown(
      input: .available(1), output: .available(1), cacheRead: .available(0),
      cacheWrite: .available(0), total: .available(2)
    )
    return UsageInsightsSummary(
      scopeKey: UsageInsightsScopeKey(provider: .codex, accountScopeID: "test"),
      generatedAt: Date(),
      source: .localCodexLogs,
      accountScope: .exact,
      sourceDescription: "Estimated from local Codex logs",
      daily: [DailyUsageInsight(
        date: today, spend: spend, tokens: tokens, sessionCount: .available(1), models: [],
        pricingCoverage: CostEstimateCoverage(pricedTokens: 2, unpricedTokens: 0)
      )]
    )
  }

  @Test func disablingTheSelectedProviderResetsToMostConstrained() throws {
    let context = try makeStore("disabled-selected-source")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 42, secondary: 68),
      .claude: snapshot(provider: .claude, primary: 95, secondary: 80),
    ]
    context.store.menuBarPreferences.setUsageSource(.provider(.claude))

    context.store.setProviderEnabled(.claude, enabled: false)

    #expect(context.store.menuBarPreferences.preferences.usageSource == .mostConstrained)
    #expect(context.store.menuBarUsedPercent == 68)
  }

  @Test func staleDisabledProviderSourceDoesNotFallBackToAnotherProvider() throws {
    let context = try makeStore("stale-disabled-source")
    defer { context.removeDefaults() }
    context.store.setProviderEnabled(.claude, enabled: false)
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 42, secondary: 68),
      .claude: snapshot(provider: .claude, primary: 95, secondary: 80),
    ]

    // Simulate stale persisted state that bypassed UsageStore's validated setter.
    context.store.menuBarPreferences.setUsageSource(.provider(.claude))

    #expect(context.store.menuBarUsedPercent == nil)
    #expect(context.store.menuBarRemainingPercent == nil)
    #expect(context.store.menuBarQuotaText == nil)
  }
}

private extension UsageStoreMenuBarTests {
  struct TestContext {
    let store: UsageStore
    let defaults: UserDefaults
    let suiteName: String

    func removeDefaults() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }

  func makeStore(_ name: String) throws -> TestContext {
    let suiteName = "UsageStoreMenuBarTests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      defaults: defaults,
      startsAutomatically: false
    )
    return TestContext(store: store, defaults: defaults, suiteName: suiteName)
  }

  func snapshot(
    provider: UsageProvider,
    primary: Double? = nil,
    secondary: Double? = nil
  ) -> UsageSnapshot {
    UsageSnapshot(
      provider: provider,
      primary: primary.map { RateWindow(kind: .session, usedPercent: $0) },
      secondary: secondary.map { RateWindow(kind: .weekly, usedPercent: $0) },
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }
}
