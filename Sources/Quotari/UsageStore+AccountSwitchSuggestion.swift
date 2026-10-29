import Foundation
import QuotariCore

extension UsageStore {
  /// After the CLI account's critical alert, suggests a monitored saved account
  /// with room. The user decides; Quotari never switches by itself (ADR 0001).
  func suggestAccountSwitch(
    afterCriticalWindows windows: [QuotaNotificationWindow],
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date
  ) async {
    guard quotaNotifications.suggestsAccountSwitch,
          let window = windows.first,
          let active = activeCLIAccounts[provider],
          account == nil || account?.id == active.id
    else { return }
    let candidates = (accounts[provider] ?? []).map { candidate in
      AccountSwitchCandidate(
        account: candidate,
        logicalID: logicalMonitoringAccountID(for: candidate),
        usage: accountUsage[provider]?[candidate.id],
        isMonitored: isMonitoring(candidate)
      )
    }
    let criteria = AccountSwitchSuggestion.Criteria(
      window: window,
      criticalUsedPercent: Double(quotaNotifications.criticalThreshold),
      now: now,
      maximumAge: max(2 * refreshInterval, 15 * 60)
    )
    guard let best = AccountSwitchSuggestion.best(
      among: candidates,
      activeLogicalID: logicalMonitoringAccountID(for: active),
      criteria: criteria
    ),
      let room = best.usage?.snapshot.flatMap({ window == .session ? $0.primary : $0.secondary })
    else { return }
    await quotaNotifications.deliverAccountSwitchAlert(AccountSwitchAlert(
      provider: provider,
      accountID: best.account.id,
      accountName: best.account.displayName,
      content: .suggestion(window: window, remainingPercent: Int(room.remainingPercent.rounded()))
    ))
  }

  /// Runs the suggestion's Switch action through the usual switch flow and
  /// its interlocks, and reports a failure the user can't otherwise see.
  func switchToSuggestedAccount(provider: UsageProvider, accountID: String) async {
    guard let account = accounts[provider]?.first(where: { $0.id == accountID }) else { return }
    captureErrors[provider] = nil
    await switchCLIAccount(to: account)
    guard let reason = captureErrors[provider] else { return }
    await quotaNotifications.deliverAccountSwitchAlert(AccountSwitchAlert(
      provider: provider,
      accountID: accountID,
      accountName: account.displayName,
      content: .failed(reason: reason)
    ))
  }

  func startAccountSwitchActionObserver() {
    _ = NotificationCenter.default.addObserver(
      forName: AccountSwitchAlert.switchRequested,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let info = notification.userInfo
      let provider = (info?[AccountSwitchAlert.UserInfoKey.provider] as? String).flatMap(UsageProvider.init(rawValue:))
      let accountID = info?[AccountSwitchAlert.UserInfoKey.accountID] as? String
      MainActor.assumeIsolated {
        guard let self, let provider, let accountID else { return }
        Task { await self.switchToSuggestedAccount(provider: provider, accountID: accountID) }
      }
    }
  }
}
