import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAccountSwitchSuggestionTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func aCriticalAlertForTheCLIAccountSuggestsTheRoomiestSavedAccount() async throws {
    let center = QuotaNotificationCenterStub(status: .authorized)
    let notifications = try await makeNotifications(center: center)
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      quotaNotifications: notifications,
      startsAutomatically: false
    )
    let live = ProviderAccount(
      provider: .codex,
      displayName: "personal",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/personal/auth.json")
    )
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "work",
      detail: nil,
      credentialSource: .quotariRegistry(id: "work")
    )
    store.accounts[.codex] = [live, saved]
    store.activeCLIAccounts[.codex] = live
    store.monitoredAccounts[.codex] = [saved]
    store.accountUsage[.codex] = [saved.id: ProviderAccountUsage(snapshot: UsageSnapshot(
      provider: .codex,
      primary: RateWindow(kind: .session, usedPercent: 30),
      secondary: RateWindow(kind: .weekly, usedPercent: 10),
      updatedAt: now
    ))]

    await store.suggestAccountSwitch(afterCriticalWindows: [], provider: .codex, account: nil, now: now)
    #expect(center.attemptedAccountSwitchAlerts.isEmpty)

    await store.suggestAccountSwitch(afterCriticalWindows: [.session], provider: .codex, account: nil, now: now)
    #expect(center.attemptedAccountSwitchAlerts == [AccountSwitchAlert(
      provider: .codex,
      accountID: saved.id,
      accountName: "work",
      content: .suggestion(window: .session, remainingPercent: 70)
    )])

    // A dashboard selection other than the CLI's account never prompts a switch.
    await store.suggestAccountSwitch(afterCriticalWindows: [.session], provider: .codex, account: saved, now: now)
    notifications.suggestsAccountSwitch = false
    await store.suggestAccountSwitch(afterCriticalWindows: [.session], provider: .codex, account: nil, now: now)
    #expect(center.attemptedAccountSwitchAlerts.count == 1)
  }

  @Test func suggestionsAreOffByDefault() throws {
    let defaults = try #require(UserDefaults(suiteName: "switch-suggestion-default-\(UUID().uuidString)"))
    let notifications = QuotaNotificationController(
      center: QuotaNotificationCenterStub(status: .authorized),
      defaults: defaults
    )

    #expect(!notifications.suggestsAccountSwitch)
  }

  private func makeNotifications(center: QuotaNotificationCenterStub) async throws -> QuotaNotificationController {
    let defaults = try #require(UserDefaults(suiteName: "switch-suggestion-\(UUID().uuidString)"))
    let notifications = QuotaNotificationController(center: center, defaults: defaults)
    _ = await notifications.setNotificationsEnabled(true)
    notifications.suggestsAccountSwitch = true
    return notifications
  }
}

extension QuotaNotificationControllerTests {
  @Test func aDeliveredCriticalAlertReportsItsWindow() async throws {
    let defaults = try makeDefaults("critical-window")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let resetAt = now.addingTimeInterval(3600)

    let warning = await controller.process(
      snapshot: snapshot(sessionUsed: 80, resetAt: resetAt), logicalAccountID: "a", sourceKind: .oauth, now: now
    )
    let critical = await controller.process(
      snapshot: snapshot(sessionUsed: 96, resetAt: resetAt), logicalAccountID: "a", sourceKind: .oauth, now: now
    )

    #expect(warning.acceptedCriticalWindows.isEmpty)
    #expect(critical.acceptedCriticalWindows == [.session])
  }
}
