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
    visible.removeAll { $0.id == account.id }
    if isMonitored {
      visible.append(account)
    }
    monitoredAccounts[provider] = visible
    try? accountMonitoringStore.save(persistedMonitoredAccounts)
  }

  func activeCLIAccount(for provider: UsageProvider) -> ProviderAccount? {
    activeCLIAccounts[provider]
  }
}
