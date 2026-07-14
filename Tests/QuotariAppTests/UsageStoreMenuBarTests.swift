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
    #expect(context.store.menuBarRemainingText == nil)
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
    context.store.menuBarPreferences.setShowsRemainingPercent(true)

    #expect(context.store.menuBarUsedPercent == nil)
    #expect(context.store.menuBarRemainingPercent == nil)
    #expect(context.store.menuBarRemainingText == nil)
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
    context.store.menuBarPreferences.setShowsRemainingPercent(true)

    #expect(context.store.menuBarUsedPercent == nil)
    #expect(context.store.menuBarRemainingPercent == nil)
    #expect(context.store.menuBarRemainingText == nil)
    #expect(context.store.menuBarAccessibilityLabel.localizedCaseInsensitiveContains("loading"))
    #expect(context.store.menuBarAccessibilityLabel.contains("Claude"))
  }

  @Test func remainingTextFollowsTheDisplayPreference() throws {
    let context = try makeStore("remaining-text")
    defer { context.removeDefaults() }
    context.store.snapshots = [
      .codex: snapshot(provider: .codex, primary: 73, secondary: 30),
    ]

    #expect(context.store.menuBarRemainingText == nil)

    context.store.menuBarPreferences.setShowsRemainingPercent(true)
    #expect(context.store.menuBarRemainingText == "27%")

    context.store.menuBarPreferences.setShowsRemainingPercent(false)
    #expect(context.store.menuBarRemainingText == nil)
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
    context.store.menuBarPreferences.setShowsRemainingPercent(true)

    #expect(context.store.menuBarUsedPercent == 64)
    #expect(context.store.menuBarRemainingText == "36%")
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
      providers: MockProviders.descriptors,
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
