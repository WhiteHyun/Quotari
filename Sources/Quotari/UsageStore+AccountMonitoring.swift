import QuotariCore

extension UsageStore {
  func isMonitoring(_ account: ProviderAccount) -> Bool {
    monitoredAccounts[account.provider]?.contains(where: { $0.id == account.id }) == true
  }

  func setMonitoring(_ isMonitored: Bool, for account: ProviderAccount) {
    let provider = account.provider
    let logicalAccount = capturedEquivalents[account.id] ?? account
    var persisted = persistedMonitoredAccounts[provider] ?? []
    persisted.removeAll { $0.id == logicalAccount.id || $0.id == account.id }
    if isMonitored {
      persisted.append(logicalAccount)
    }
    persistedMonitoredAccounts[provider] = persisted

    var visible = monitoredAccounts[provider] ?? []
    visible.removeAll { visibleAccount in
      let visibleLogicalAccount = capturedEquivalents[visibleAccount.id] ?? visibleAccount
      return visibleAccount.id == account.id
        || visibleLogicalAccount.id == logicalAccount.id
    }
    if isMonitored {
      visible.append(account)
    }
    monitoredAccounts[provider] = visible
    // A direct user action is authoritative enough to repair a malformed file
    // or retry a previous write failure. Automatic reconciliation continues
    // to fail closed through the default persistence path.
    persistMonitoringSelections(allowsRecovery: true)
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
