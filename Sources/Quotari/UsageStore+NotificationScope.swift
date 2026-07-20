import Foundation
import QuotariCore

extension UsageStore {
  func quotaNotificationAccountResolution(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) async -> QuotaNotificationAccountResolution {
    if let account {
      guard case let .current(claudeCredentialFingerprint) = notificationFetchCredentialValidation(
        account: account,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID
      ) else { return .staleCredential }
      let logicalAccount = if provider == .claude {
        account
      } else if selectedAccounts[provider]?.id == account.id {
        reconciledSelectionOrigins[provider] ?? account
      } else {
        account
      }
      return notificationScopeResolution(
        for: logicalAccount,
        claudeCredentialFingerprint: claudeCredentialFingerprint
      )
    }
    if let origin = reconciledSelectionOrigins[provider] {
      guard case let .current(claudeCredentialFingerprint) = notificationFetchCredentialValidation(
        account: origin,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID
      ) else { return .staleCredential }
      return notificationScopeResolution(
        for: origin,
        claudeCredentialFingerprint: claudeCredentialFingerprint
      )
    }
    if let matchedAccount = matchedAccount(for: snapshot, provider: provider) {
      guard case let .current(claudeCredentialFingerprint) = notificationFetchCredentialValidation(
        account: matchedAccount,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID
      ) else { return .staleCredential }
      return notificationScopeResolution(
        for: matchedAccount,
        claudeCredentialFingerprint: claudeCredentialFingerprint
      )
    }
    guard snapshot.account == nil else { return .unattributed }
    return await automaticNotificationAccountResolution(
      provider: provider,
      sourceKind: sourceKind,
      credentialScopeID: credentialScopeID
    )
  }

  private enum NotificationFetchCredentialValidation {
    case current(claudeCredentialFingerprint: String?)
    case stale
  }

  private func notificationFetchCredentialValidation(
    account: ProviderAccount,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) -> NotificationFetchCredentialValidation {
    guard sourceKind == .oauth, let credentialScopeID else {
      return .current(claudeCredentialFingerprint: nil)
    }
    switch account.provider {
    case .codex:
      if !account.credentialSource.isCaptured,
         account.credentialScopeID != credentialScopeID {
        return .stale
      }
      guard let credentials = codexCredentialLoader(account.credentialSource) else { return .stale }
      let identity = credentials.accountID
        ?? credentials.email
        ?? credentials.refreshToken
        ?? credentials.accessToken
      let currentAccount = ProviderAccount(
        provider: account.provider,
        displayName: account.displayName,
        detail: account.detail,
        credentialSource: account.credentialSource,
        credentialIdentity: identity
      )
      return currentAccount.credentialScopeID == credentialScopeID
        ? .current(claudeCredentialFingerprint: nil)
        : .stale
    case .claude:
      guard let credentials = claudeCredentialLoader(account.credentialSource) else { return .stale }
      let currentAccount = ProviderAccount(
        provider: account.provider,
        displayName: account.displayName,
        detail: account.detail,
        credentialSource: account.credentialSource,
        credentialIdentity: credentials.accessToken
      )
      guard currentAccount.credentialScopeID == credentialScopeID else { return .stale }
      return .current(
        claudeCredentialFingerprint: ProviderCredentialIdentity.fingerprint(
          of: credentials.accessToken
        )
      )
    }
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
        switch $0.credentialSource {
        case .codexAuthFile, .codexKeychain:
          true
        case .claudeEnvironment, .claudeKeychain, .claudeCredentialsFile, .quotariRegistry:
          false
        }
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
      guard case let .current(claudeCredentialFingerprint) = notificationFetchCredentialValidation(
        account: account,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID
      ) else { return .staleCredential }
      return notificationScopeResolution(
        forLogicalAccount: account,
        claudeCredentialFingerprint: claudeCredentialFingerprint
      )
    }
  }

  func notificationScopeID(for account: ProviderAccount) -> String? {
    notificationScopeResolution(for: account).logicalAccountID
  }

  func lastKnownNotificationScopeID(for account: ProviderAccount) -> String? {
    if let scopeID = notificationScopeIDsByAccountID[account.id] {
      return scopeID
    }
    switch account.provider {
    case .codex:
      return notificationScopeID(for: account)
    case .claude:
      guard let profile = claudeProfiles[account.id],
            let identity = stableClaudeNotificationIdentity(from: profile)
      else { return nil }
      return "claude:account:\(ProviderCredentialIdentity.fingerprint(of: identity))"
    }
  }

  private func notificationScopeResolution(
    for account: ProviderAccount,
    claudeCredentialFingerprint: String? = nil
  ) -> QuotaNotificationAccountResolution {
    let logicalAccount = account.provider == .claude
      ? account
      : capturedEquivalents[account.id] ?? account
    return notificationScopeResolution(
      forLogicalAccount: logicalAccount,
      claudeCredentialFingerprint: claudeCredentialFingerprint
    )
  }

  private func notificationScopeResolution(
    forLogicalAccount account: ProviderAccount,
    claudeCredentialFingerprint: String? = nil
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
      guard let profile = verifiedClaudeNotificationProfile(
        for: account,
        credentialFingerprint: claudeCredentialFingerprint
      ) else {
        if hasConfirmedEmptyClaudeProfile(
          for: account,
          credentialFingerprint: claudeCredentialFingerprint
        ) {
          return .unattributed
        }
        return .deferredClaudeIdentity
      }
      guard let identity = stableClaudeNotificationIdentity(from: profile) else {
        return .unattributed
      }
      return .resolved("claude:account:\(ProviderCredentialIdentity.fingerprint(of: identity))")
    }
  }

  private func hasConfirmedEmptyClaudeProfile(
    for account: ProviderAccount,
    credentialFingerprint: String?
  ) -> Bool {
    let fingerprint = credentialFingerprint ?? claudeCredentialLoader(account.credentialSource).map {
      ProviderCredentialIdentity.fingerprint(of: $0.accessToken)
    }
    guard let fingerprint else { return false }
    return emptyClaudeProfileFingerprints[account.id] == fingerprint
  }

  private func verifiedClaudeNotificationProfile(
    for account: ProviderAccount,
    credentialFingerprint: String? = nil
  ) -> ClaudeProfile? {
    guard let profile = claudeProfiles[account.id],
          let expectedFingerprint = profile.fingerprint
    else { return nil }
    if let credentialFingerprint {
      guard credentialFingerprint == expectedFingerprint else { return nil }
      return profile
    }
    guard let credentials = claudeCredentialLoader(account.credentialSource),
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
    case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeKeychain, .quotariRegistry:
      nil
    }
  }
}
