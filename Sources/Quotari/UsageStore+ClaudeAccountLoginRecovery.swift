import Foundation
import QuotariCore

extension UsageStore {
  func restoreClaudeAccountIfNeeded(
    preservingDashboardSelection dashboardSelection: ProviderAccount?,
    registryBaseline: AccountLoginRegistryBaseline?,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot?
  ) async -> String? {
    guard let registryBaseline,
          registryBaseline.isCredentialMutationPossible,
          let keychainSnapshot = registryBaseline.claudeKeychainSnapshot
    else { return nil }
    guard let postLoginSnapshot = registryBaseline.claudePostLoginSnapshot else {
      beginAccountRediscovery()
      return L10n.string(
        """
        Quotari couldn’t verify the post-login Claude credential and account state, so it left the current CLI login \
        untouched instead of risking a newer external generation.
        """
      )
    }
    return await restoreExactClaudeLoginState(
      keychainSnapshot,
      postLoginSnapshot: postLoginSnapshot,
      dashboardSelection: dashboardSelection,
      allowingActiveSessions: activitySnapshot
    )
  }

  private func restoreExactClaudeLoginState(
    _ keychainSnapshot: ClaudeKeychainLoginSnapshot,
    postLoginSnapshot: ClaudeKeychainLoginSnapshot,
    dashboardSelection: ProviderAccount?,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot?
  ) async -> String? {
    accountLoginPhases[.claude] = .restoringPreviousAccount
    let switcher = accountSwitch
    do {
      try await Task.detached {
        try switcher.restoreClaudeLogin(
          keychain: keychainSnapshot.payload,
          replacing: postLoginSnapshot.payload,
          accountState: keychainSnapshot.accountState,
          replacingAccountState: postLoginSnapshot.accountState,
          allowingActiveSessions: activitySnapshot
        )
      }.value
    } catch {
      beginAccountRediscovery()
      return error.localizedDescription
    }
    await reloadAccountsDuringSwitch()
    restoreClaudeDashboardSelection(dashboardSelection)
    return nil
  }

  private func restoreClaudeDashboardSelection(_ savedSelection: ProviderAccount?) {
    let visibleSelection = savedSelection.flatMap { saved in
      accounts[.claude]?.first(where: { account in
        account.id == saved.id || capturedEquivalents[account.id]?.id == saved.id
      }) ?? saved
    }
    selectAccount(visibleSelection, for: .claude)
  }

  func liveClaudeCredentialSlotAccount() -> ProviderAccount? {
    let liveAccounts = accounts[.claude] ?? []
    return liveAccounts.first(where: { account in
      if case .claudeKeychain = account.credentialSource {
        return true
      }
      return false
    }) ?? liveAccounts.first(where: { account in
      if case .claudeCredentialsFile = account.credentialSource {
        return true
      }
      return false
    })
  }
}
