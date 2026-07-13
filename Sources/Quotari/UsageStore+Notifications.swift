import Foundation
import QuotariCore

extension UsageStore {
  func enqueueQuotaNotification(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) {
    // Automatic mode has no selected account to establish scope. Resolve the
    // live identity in the serial notification tail so the matching process
    // uses the same freshly-discovered account. A transient mock fallback
    // preserves the last real scope and cannot notify.
    let updatesAutomaticScope = account == nil && sourceKind != .mock
    let revision = accountRevisions[provider] ?? 0
    let previous = quotaNotificationTask
    let controller = quotaNotifications
    quotaNotificationTask = Task { [weak self] in
      await previous?.value
      guard let self,
            (accountRevisions[provider] ?? 0) == revision
      else { return }
      let logicalAccountID = await quotaNotificationAccountID(
        snapshot: snapshot,
        provider: provider,
        account: account,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID
      )
      guard (accountRevisions[provider] ?? 0) == revision else { return }
      if updatesAutomaticScope {
        controller.setActiveLogicalAccountID(logicalAccountID, for: provider)
      }
      _ = await controller.process(
        snapshot: snapshot,
        logicalAccountID: logicalAccountID,
        sourceKind: sourceKind,
        now: snapshot.updatedAt,
        isCurrent: { [weak self] in
          guard let self else { return false }
          return (accountRevisions[provider] ?? 0) == revision
        }
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
    let scopeID = (origin ?? account).map { notificationScopeID(for: $0) }
    quotaNotifications.setActiveLogicalAccountID(
      scopeID,
      for: provider
    )
  }

  private func quotaNotificationAccountID(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) async -> String? {
    guard sourceKind != .mock else { return nil }
    if let origin = reconciledSelectionOrigins[provider] {
      return notificationScopeID(for: origin)
    }
    if let account {
      return notificationScopeID(for: account)
    }
    if let matchedAccount = matchedAccount(for: snapshot, provider: provider) {
      return notificationScopeID(for: matchedAccount)
    }
    guard snapshot.account == nil else { return nil }
    return await automaticNotificationAccountID(
      provider: provider,
      sourceKind: sourceKind,
      credentialScopeID: credentialScopeID
    )
  }

  private func automaticNotificationAccountID(
    provider: UsageProvider,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) async -> String? {
    guard sourceKind == .oauth, let credentialScopeID else { return nil }
    // Automatic fetches read the live credential directly. Rediscover after
    // that fetch instead of consulting the last account scan, so an external
    // login replacement cannot inherit the previous slot occupant's ledger.
    let discoveredAccounts = await accountDiscovery.accounts(for: provider)
    let currentCapturedCopies = await accountDiscovery.capturedCopies(
      among: discoveredAccounts
    )
    let account: ProviderAccount?
    switch provider {
    case .codex:
      let liveAccounts = discoveredAccounts.filter {
        if case .codexAuthFile = $0.credentialSource {
          return true
        }
        return false
      }
      account = liveAccounts.count == 1 ? liveAccounts[0] : nil
    case .claude:
      account = discoveredAccounts
        .compactMap { account -> (rank: Int, account: ProviderAccount)? in
          guard let rank = Self.automaticClaudeSourceRank(account.credentialSource) else { return nil }
          return (rank, account)
        }
        .min { $0.rank < $1.rank }?
        .account
    }
    guard let account, account.credentialScopeID == credentialScopeID else { return nil }
    return notificationScopeID(
      forLogicalAccount: currentCapturedCopies[account.id] ?? account
    )
  }

  private func notificationScopeID(for account: ProviderAccount) -> String {
    notificationScopeID(forLogicalAccount: capturedEquivalents[account.id] ?? account)
  }

  private func notificationScopeID(forLogicalAccount account: ProviderAccount) -> String {
    switch account.provider {
    case .codex:
      account.credentialScopeID
    case .claude:
      // Claude discovery can only key an unsaved live account by its access
      // token. That token rotates during routine refreshes, so keep the
      // notification ledger on the durable source/registry id instead.
      account.id
    }
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
