import Foundation
import QuotariCore

extension UsageStore {
  func enqueueQuotaNotification(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?
  ) {
    let logicalAccountID = quotaNotificationAccountID(
      snapshot: snapshot,
      provider: provider,
      account: account,
      sourceKind: sourceKind
    )
    // Automatic mode has no selected account to establish scope. Every real
    // provider result replaces the prior scope before queued work runs; an
    // unattributed result clears stale reset schedules rather than letting the
    // previous account's reminder survive. A transient mock fallback preserves
    // the last real scope and cannot create notifications itself.
    if account == nil, sourceKind != .mock {
      quotaNotifications.setActiveLogicalAccountID(logicalAccountID, for: provider)
    }
    let previous = quotaNotificationTask
    let controller = quotaNotifications
    quotaNotificationTask = Task {
      await previous?.value
      _ = await controller.process(
        snapshot: snapshot,
        logicalAccountID: logicalAccountID,
        sourceKind: sourceKind,
        now: snapshot.updatedAt
      )
    }
  }

  func waitForPendingQuotaNotifications() async {
    await quotaNotificationTask?.value
  }

  func synchronizeQuotaNotificationScope(
    account: ProviderAccount?,
    origin: ProviderAccount?,
    provider: UsageProvider
  ) {
    quotaNotifications.setActiveLogicalAccountID(
      origin?.id ?? account?.id,
      for: provider
    )
  }

  private func quotaNotificationAccountID(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?
  ) -> String? {
    guard sourceKind != .mock else { return nil }
    if let origin = reconciledSelectionOrigins[provider] {
      return origin.id
    }
    if let account {
      return account.id
    }
    if let matchedAccount = matchedAccount(for: snapshot, provider: provider) {
      return capturedEquivalents[matchedAccount.id]?.id ?? matchedAccount.id
    }
    guard snapshot.account == nil else { return nil }
    return automaticClaudeNotificationAccountID(
      provider: provider,
      sourceKind: sourceKind
    )
  }

  private func automaticClaudeNotificationAccountID(
    provider: UsageProvider,
    sourceKind: ProviderFetchKind?
  ) -> String? {
    guard provider == .claude, sourceKind == .oauth else { return nil }
    let account = (accounts[provider] ?? [])
      .compactMap { account -> (rank: Int, account: ProviderAccount)? in
        guard let rank = Self.automaticClaudeSourceRank(account.credentialSource) else { return nil }
        return (rank, account)
      }
      .min { $0.rank < $1.rank }?
      .account
    guard let account else { return nil }
    return capturedEquivalents[account.id]?.id ?? account.id
  }

  private nonisolated static func automaticClaudeSourceRank(
    _ source: ProviderCredentialSource
  ) -> Int? {
    switch source {
    case let .claudeEnvironment(name) where name == ClaudeCredentialsStore.tokenEnvKey:
      0
    case let .claudeKeychain(service) where service == ClaudeCredentialsStore.keychainService:
      1
    case .claudeCredentialsFile:
      2
    case .codexAuthFile, .claudeEnvironment, .claudeKeychain, .quotariRegistry:
      nil
    }
  }
}
