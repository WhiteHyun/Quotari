import Foundation
import QuotariCore

struct DeferredClaudeQuotaNotification {
  var snapshot: UsageSnapshot
  var account: ProviderAccount?
  var sourceKind: ProviderFetchKind?
  var credentialScopeID: String?
  var revision: UInt
}

private enum QuotaNotificationAccountResolution {
  case resolved(String)
  case deferredClaudeIdentity
  case unattributed

  var logicalAccountID: String? {
    guard case let .resolved(id) = self else { return nil }
    return id
  }
}

extension UsageStore {
  func enqueueQuotaNotification(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) {
    guard isProviderEnabled(provider) else { return }
    // Automatic mode has no selected account to establish scope. Its real
    // results update scope inside the serial notification tail below: this
    // keeps a reactivation's nil-scope drain ahead of the fresh identity and
    // prevents a pre-disable snapshot from being revived. A transient mock
    // fallback preserves the last real scope and cannot notify.
    let updatesAutomaticScope = account == nil && sourceKind != .mock
    let revision = accountRevisions[provider] ?? 0
    let previous = quotaNotificationTask
    quotaNotificationTask = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      await processQuotaNotification(
        snapshot: snapshot,
        provider: provider,
        account: account,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID,
        revision: revision,
        updatesAutomaticScope: updatesAutomaticScope
      )
    }
  }

  private func processQuotaNotification(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?,
    revision: UInt,
    updatesAutomaticScope: Bool
  ) async {
    guard isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == revision
    else { return }
    let resolution = await quotaNotificationAccountResolution(
      snapshot: snapshot,
      provider: provider,
      account: account,
      sourceKind: sourceKind,
      credentialScopeID: credentialScopeID
    )
    guard isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == revision
    else { return }

    switch resolution {
    case .deferredClaudeIdentity:
      deferredClaudeQuotaNotification = DeferredClaudeQuotaNotification(
        snapshot: snapshot,
        account: account,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID,
        revision: revision
      )
      return
    case .resolved:
      if provider == .claude {
        deferredClaudeQuotaNotification = nil
      }
    case .unattributed:
      if provider == .claude, sourceKind != .mock {
        deferredClaudeQuotaNotification = nil
      }
    }

    let logicalAccountID = resolution.logicalAccountID
    let controller = quotaNotifications
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
        return isProviderEnabled(provider)
          && (accountRevisions[provider] ?? 0) == revision
      }
    )
  }

  func enqueueClaudeQuotaNotificationScopeRestore() {
    let provider = UsageProvider.claude
    let revision = accountRevisions[provider] ?? 0
    let previous = quotaNotificationTask
    quotaNotificationTask = Task { [weak self] in
      await previous?.value
      guard let self,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == revision
      else { return }
      if let deferred = deferredClaudeQuotaNotification {
        guard deferred.revision == revision else {
          deferredClaudeQuotaNotification = nil
          synchronizeQuotaNotificationScope(
            account: selectedAccounts[provider],
            origin: reconciledSelectionOrigins[provider],
            provider: provider
          )
          return
        }
        await processQuotaNotification(
          snapshot: deferred.snapshot,
          provider: provider,
          account: deferred.account,
          sourceKind: deferred.sourceKind,
          credentialScopeID: deferred.credentialScopeID,
          revision: deferred.revision,
          updatesAutomaticScope: deferred.account == nil && deferred.sourceKind != .mock
        )
        return
      }
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[provider],
        origin: reconciledSelectionOrigins[provider],
        provider: provider
      )
    }
  }

  func enqueueQuotaNotificationScopeRestore(for provider: UsageProvider) {
    let revision = accountRevisions[provider] ?? 0
    let previous = quotaNotificationTask
    quotaNotificationTask = Task { [weak self] in
      await previous?.value
      guard let self,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == revision
      else { return }
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[provider],
        origin: reconciledSelectionOrigins[provider],
        provider: provider
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
    let scopeID = (origin ?? account).flatMap { notificationScopeID(for: $0) }
    quotaNotifications.setActiveLogicalAccountID(
      isProviderEnabled(provider) ? scopeID : nil,
      for: provider
    )
  }

  private func quotaNotificationAccountResolution(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) async -> QuotaNotificationAccountResolution {
    guard sourceKind != .mock else { return .unattributed }
    if let origin = reconciledSelectionOrigins[provider] {
      return notificationScopeResolution(for: origin)
    }
    if let account {
      return notificationScopeResolution(for: account)
    }
    if let matchedAccount = matchedAccount(for: snapshot, provider: provider) {
      return notificationScopeResolution(for: matchedAccount)
    }
    guard snapshot.account == nil else { return .unattributed }
    return await automaticNotificationAccountResolution(
      provider: provider,
      sourceKind: sourceKind,
      credentialScopeID: credentialScopeID
    )
  }

  private func automaticNotificationAccountResolution(
    provider: UsageProvider,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) async -> QuotaNotificationAccountResolution {
    guard sourceKind == .oauth, let credentialScopeID else { return .unattributed }
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
      account = liveAccounts.first { $0.credentialScopeID == credentialScopeID }
    case .claude:
      account = discoveredAccounts
        .compactMap { account -> (rank: Int, account: ProviderAccount)? in
          guard let rank = Self.automaticClaudeSourceRank(account.credentialSource) else { return nil }
          return (rank, account)
        }
        .min { $0.rank < $1.rank }?
        .account
    }
    guard let account, account.credentialScopeID == credentialScopeID else { return .unattributed }
    switch provider {
    case .codex:
      return notificationScopeResolution(
        forLogicalAccount: currentCapturedCopies[account.id] ?? account
      )
    case .claude:
      return notificationScopeResolution(forLogicalAccount: account)
    }
  }

  private func notificationScopeID(for account: ProviderAccount) -> String? {
    notificationScopeResolution(for: account).logicalAccountID
  }

  private func notificationScopeResolution(
    for account: ProviderAccount
  ) -> QuotaNotificationAccountResolution {
    let logicalAccount = account.provider == .claude
      ? account
      : capturedEquivalents[account.id] ?? account
    return notificationScopeResolution(forLogicalAccount: logicalAccount)
  }

  private func notificationScopeResolution(
    forLogicalAccount account: ProviderAccount
  ) -> QuotaNotificationAccountResolution {
    switch account.provider {
    case .codex:
      return .resolved(account.credentialScopeID)
    case .claude:
      // A Claude source can be reused by a different login, while its access
      // token also rotates for the same login. Only a profile verified against
      // the source's current token distinguishes those cases safely. Delay
      // alerts until that stable identity is available instead of assigning
      // another account's snapshot or ledger history to this slot.
      guard let profile = verifiedClaudeNotificationProfile(for: account) else {
        return .deferredClaudeIdentity
      }
      guard let identity = stableClaudeNotificationIdentity(from: profile) else {
        return .unattributed
      }
      return .resolved("claude:account:\(ProviderCredentialIdentity.fingerprint(of: identity))")
    }
  }

  private func verifiedClaudeNotificationProfile(for account: ProviderAccount) -> ClaudeProfile? {
    guard let profile = claudeProfiles[account.id],
          let expectedFingerprint = profile.fingerprint,
          let credentials = claudeCredentialLoader(account.credentialSource),
          ProviderCredentialIdentity.fingerprint(of: credentials.accessToken) == expectedFingerprint
    else { return nil }
    return profile
  }

  private func stableClaudeNotificationIdentity(from profile: ClaudeProfile) -> String? {
    if let accountID = profile.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
       !accountID.isEmpty {
      return "id:\(accountID)"
    }
    guard let email = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines),
          !email.isEmpty
    else { return nil }
    return "email:\(email.lowercased())"
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
