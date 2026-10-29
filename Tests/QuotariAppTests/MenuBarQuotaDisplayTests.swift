import Foundation
@testable import Quotari
import QuotariCore
import Testing

struct MenuBarQuotaDisplayTests {
  private let snapshot = UsageSnapshot(
    provider: .codex,
    primary: RateWindow(kind: .session, usedPercent: 40, resetsAt: nil),
    secondary: RateWindow(kind: .weekly, usedPercent: 70, resetsAt: nil),
    updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
  )

  @Test func sessionWindowReadsTheSessionQuota() {
    #expect(MenuBarQuotaDisplay.usedPercent(in: snapshot, window: .session) == 40)
  }

  @Test func weeklyWindowReadsTheWeeklyQuota() {
    #expect(MenuBarQuotaDisplay.usedPercent(in: snapshot, window: .weekly) == 70)
  }

  @Test func automaticReadsTheMostConstrainedStandardWindow() {
    #expect(MenuBarQuotaDisplay.usedPercent(in: snapshot, window: .automatic) == 70)
  }

  @Test func automaticFallsBackToNamedWindowsWithoutStandardOnes() {
    let extrasOnly = UsageSnapshot(
      provider: .codex,
      extraWindows: [
        NamedWindow(title: "A", window: RateWindow(kind: .weekly, usedPercent: 15, resetsAt: nil)),
        NamedWindow(title: "B", window: RateWindow(kind: .weekly, usedPercent: 55, resetsAt: nil)),
      ],
      updatedAt: snapshot.updatedAt
    )

    #expect(MenuBarQuotaDisplay.usedPercent(in: extrasOnly, window: .automatic) == 55)
    #expect(MenuBarQuotaDisplay.usedPercent(in: extrasOnly, window: .session) == nil)
  }

  @Test func textShowsRemainingOrMarkedUsedPercent() {
    #expect(MenuBarQuotaDisplay.text(usedPercent: 32.4, presentation: .remaining) == "68%")
    #expect(MenuBarQuotaDisplay.text(usedPercent: 32.4, presentation: .used) == "↑32%")
  }
}

struct MenuBarQuotaPreferencesMigrationTests {
  @Test func preferencesSavedBeforeWindowChoiceKeepTheirValuesAndDefaultTheRest() throws {
    let legacy = Data("""
    { "showsRemainingPercent": true, "usageSource": { "provider": { "_0": "codex" } }, "animatesMascot": false }
    """.utf8)

    let preferences = try JSONDecoder().decode(MenuBarPreferences.self, from: legacy)

    #expect(preferences == MenuBarPreferences(
      valueMode: .remainingQuota,
      usageSource: .provider(.codex),
      animatesMascot: false,
      quotaWindow: .automatic,
      quotaPresentation: .remaining,
      costSource: nil
    ))
  }

  @Test func hiddenLegacyPercentageBecomesTheHiddenMode() throws {
    let legacy = Data("""
    { "showsRemainingPercent": false, "usageSource": { "mostConstrained": {} }, "animatesMascot": true }
    """.utf8)

    let preferences = try JSONDecoder().decode(MenuBarPreferences.self, from: legacy)

    #expect(preferences.valueMode == .hidden)
    #expect(preferences.costSource == nil)
  }

  @Test func savedPreferencesStayReadableByEarlierVersions() throws {
    let preferences = MenuBarPreferences(valueMode: .todayCost, costSource: .claude)

    let json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any]
    )

    // Earlier versions require this key; a cost mode reads there as hidden.
    #expect(json["showsRemainingPercent"] as? Bool == false)
    #expect(try JSONDecoder().decode(MenuBarPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
  }
}
