import QuotariCore

extension UsageStore {
  func isMonitoring(_ account: ProviderAccount) -> Bool {
    monitoredAccounts[account.provider]?.contains(where: { $0.id == account.id }) == true
  }

  func includeAccountInAutomaticMonitoring(_ account: ProviderAccount) {
    let provider = account.provider
    if monitoredAccounts[provider]?.contains(where: { $0.id == account.id }) != true {
      monitoredAccounts[provider, default: []].append(account)
    }
    let logicalAccount = capturedEquivalents[account.id] ?? account
    if persistedMonitoredAccounts[provider]?.contains(where: { $0.id == logicalAccount.id }) != true {
      persistedMonitoredAccounts[provider, default: []].append(logicalAccount)
      persistMonitoringSelections(allowsRecovery: true)
    }
  }

  func persistMonitoringSelections(allowsRecovery: Bool = false) {
    guard isMonitoringConfigurationLoaded || allowsRecovery else { return }
    do {
      try accountMonitoringStore.save(persistedMonitoredAccounts)
      isMonitoringConfigurationLoaded = true
    } catch {
      // An atomic write failure should not be followed by later writes based
      // on a state that was never durably established. A later direct user
      // action may retry this same recovery path.
      isMonitoringConfigurationLoaded = false
    }
  }

  func activeCLIAccount(for provider: UsageProvider) -> ProviderAccount? {
    activeCLIAccounts[provider]
  }
}
