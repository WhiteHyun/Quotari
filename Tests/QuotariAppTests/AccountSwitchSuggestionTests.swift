import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

struct AccountSwitchSuggestionTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private var criteria: AccountSwitchSuggestion.Criteria {
    .init(window: .session, criticalUsedPercent: 95, now: now, maximumAge: 15 * 60)
  }

  @Test func theMonitoredSavedAccountWithTheMostSessionRoomWins() {
    let candidates = [
      candidate("work", session: 40, weekly: 10),
      candidate("side", session: 20, weekly: 50),
      candidate("live", session: 0, weekly: 0, saved: false),
    ]

    let best = AccountSwitchSuggestion.best(among: candidates, activeLogicalID: "personal", criteria: criteria)

    #expect(best?.account.displayName == "side")
  }

  @Test func staleFailedUnmonitoredAndActiveAccountsAreNeverSuggested() {
    let candidates = [
      candidate("stale", session: 0, weekly: 0, age: 20 * 60),
      candidate("failed", session: 0, weekly: 0, error: "401"),
      candidate("unmonitored", session: 0, weekly: 0, monitored: false),
      candidate("personal", session: 0, weekly: 0),
      candidate("weekly-out", session: 0, weekly: 96),
      candidate("no-data", session: nil, weekly: nil),
    ]

    #expect(AccountSwitchSuggestion.best(among: candidates, activeLogicalID: "personal", criteria: criteria) == nil)
  }

  @Test func tiesGoToTheOtherWindowThenToListOrder() {
    let byWeekly = [candidate("a", session: 30, weekly: 60), candidate("b", session: 30, weekly: 20)]
    let byOrder = [candidate("a", session: 30, weekly: 20), candidate("b", session: 30, weekly: 20)]

    #expect(AccountSwitchSuggestion.best(among: byWeekly, activeLogicalID: "x", criteria: criteria)?.account
      .displayName == "b")
    #expect(AccountSwitchSuggestion.best(among: byOrder, activeLogicalID: "x", criteria: criteria)?.account
      .displayName == "a")
  }

  private func candidate(
    _ name: String,
    session: Double?,
    weekly: Double?,
    age: TimeInterval = 60,
    error: String? = nil,
    monitored: Bool = true,
    saved: Bool = true
  ) -> AccountSwitchCandidate {
    let account = ProviderAccount(
      provider: .codex,
      displayName: name,
      detail: nil,
      credentialSource: saved ? .quotariRegistry(id: name) : .codexAuthFile(path: "/tmp/\(name)/auth.json")
    )
    let snapshot = session.map { session in
      UsageSnapshot(
        provider: .codex,
        primary: RateWindow(kind: .session, usedPercent: session),
        secondary: weekly.map { RateWindow(kind: .weekly, usedPercent: $0) },
        updatedAt: now.addingTimeInterval(-age)
      )
    }
    return AccountSwitchCandidate(
      account: account,
      logicalID: name,
      usage: ProviderAccountUsage(snapshot: snapshot, error: error),
      isMonitored: monitored
    )
  }
}
