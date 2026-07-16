import Foundation
import QuotariCore

extension UsageStore {
  func restoreClaudeAccountIfNeeded(
    preservingDashboardSelection dashboardSelection: ProviderAccount?,
    registryBaseline: AccountLoginRegistryBaseline?
  ) async -> String? {
    guard let registryBaseline,
          registryBaseline.isCredentialMutationPossible,
          let keychainSnapshot = registryBaseline.claudeKeychainSnapshot
    else { return nil }
    return await restoreExactClaudeKeychainState(
      keychainSnapshot,
      dashboardSelection: dashboardSelection
    )
  }

  private func restoreExactClaudeKeychainState(
    _ keychainSnapshot: ClaudeKeychainLoginSnapshot,
    dashboardSelection: ProviderAccount?
  ) async -> String? {
    accountLoginPhases[.claude] = .restoringPreviousAccount
    let switcher = accountSwitch
    do {
      try await Task.detached {
        try switcher.restoreClaudeLoginKeychain(to: keychainSnapshot.payload)
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
