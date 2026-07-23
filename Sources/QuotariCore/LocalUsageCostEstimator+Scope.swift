import Foundation

extension LocalUsageCostEstimator {
  func resolvedInsightsScope(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition? = nil
  ) -> ResolvedUsageInsightsScope? {
    guard account?.provider == provider || account == nil else { return nil }
    guard let account else {
      return sharedInsightsScope(provider: provider, account: nil)
    }

    switch (provider, account.credentialSource) {
    case (.codex, .codexAuthFile), (.claude, .claudeCredentialsFile):
      guard exactCredentialSourceStillBelongs(
        to: account,
        credentialTransition: credentialTransition
      ) else { return nil }
      return sharedInsightsScope(provider: provider, account: account)
    case (.codex, .codexKeychain), (.claude, .claudeEnvironment), (.claude, .claudeKeychain):
      return sharedInsightsScope(provider: provider, account: account)
    case (_, .quotariRegistry),
         (.codex, .claudeEnvironment),
         (.codex, .claudeKeychain),
         (.codex, .claudeCredentialsFile),
         (.claude, .codexAuthFile),
         (.claude, .codexKeychain):
      return nil
    }
  }

  func invalidateUnresolvedCredentialScope(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  ) {
    guard let account, account.provider == provider else { return }
    switch (provider, account.credentialSource) {
    case (.codex, .codexAuthFile), (.claude, .claudeCredentialsFile):
      break
    case (.codex, .codexKeychain),
         (.codex, .claudeEnvironment),
         (.codex, .claudeKeychain),
         (.codex, .claudeCredentialsFile),
         (.codex, .quotariRegistry),
         (.claude, .codexAuthFile),
         (.claude, .codexKeychain),
         (.claude, .claudeEnvironment),
         (.claude, .claudeKeychain),
         (.claude, .quotariRegistry):
      return
    }
    guard let scope = sharedInsightsScope(provider: provider, account: account) else { return }
    let historyDays = normalizedHistoryDays(historyDays)
    let key = LocalUsageCacheMutationKey(scopeKey: scope.key, historyDays: historyDays)
    cacheCoordinator.invalidate(key: key) {
      removeCachedAnalysis(provider: provider, scope: scope, historyDays: historyDays)
    }
  }

  func normalizedHistoryDays(_ historyDays: Int) -> Int {
    max(1, min(365, historyDays))
  }

  private func sharedInsightsScope(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> ResolvedUsageInsightsScope? {
    let roots = LocalUsageCostScanner(
      environment: environment,
      homeDirectory: homeDirectory
    )
    .scopeIdentityRoots(provider: provider, account: account)
    guard !roots.isEmpty else { return nil }
    let rootIdentity = scopeIdentityStore.identities(for: roots).joined(separator: "\n")
    return ResolvedUsageInsightsScope(
      key: UsageInsightsScopeKey(
        provider: provider,
        accountScopeID: "shared:\(ProviderCredentialIdentity.fingerprint(of: rootIdentity))"
      ),
      accountScope: .sharedLocalCache,
      previousCostScopeID: account?.costCacheScopeID
    )
  }

  private func exactCredentialSourceStillBelongs(
    to account: ProviderAccount,
    credentialTransition: UsageCostCredentialTransition?
  ) -> Bool {
    let path: String
    switch account.credentialSource {
    case let .codexAuthFile(credentialPath), let .claudeCredentialsFile(credentialPath):
      path = credentialPath
    case .codexKeychain, .claudeEnvironment, .claudeKeychain, .quotariRegistry:
      return false
    }
    guard let payload = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let identity = ProviderCredentialIdentity.discoveredAccountIdentity(
            provider: account.provider,
            payload: payload
          )
    else { return false }
    let currentAccount = ProviderAccount(
      provider: account.provider,
      displayName: account.displayName,
      detail: account.detail,
      credentialSource: account.credentialSource,
      credentialIdentity: identity
    )
    if currentAccount.credentialScopeID == account.credentialScopeID {
      return true
    }
    guard let credentialTransition else { return false }
    return credentialTransition.sourceScopeIDs.contains(account.credentialScopeID)
      && credentialTransition.targetScopeID == currentAccount.credentialScopeID
  }
}
