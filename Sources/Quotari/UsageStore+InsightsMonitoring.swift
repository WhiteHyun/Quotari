import QuotariCore

extension UsageStore {
  func reconfigureUsageInsightsMonitoring() {
    let observations: [UsageInsightsLogObservation] = enabledProviderDescriptors.compactMap { descriptor in
      let account = selectedAccounts[descriptor.id]
      let roots = costEstimator.usageInsightsObservationRoots(
        provider: descriptor.id,
        account: account
      )
      guard !roots.isEmpty else { return nil }
      return UsageInsightsLogObservation(
        key: UsageInsightsObservationKey(
          provider: descriptor.id,
          credentialScopeID: account?.credentialScopeID
        ),
        roots: roots
      )
    }
    usageInsightsChangeMonitor.replaceObservations(observations) { [weak self] keys in
      Task { @MainActor [weak self] in
        self?.refreshUsageInsightsAfterLogChanges(keys)
      }
    }
  }

  private func refreshUsageInsightsAfterLogChanges(
    _ keys: Set<UsageInsightsObservationKey>
  ) {
    for key in keys {
      guard isProviderEnabled(key.provider),
            selectedAccounts[key.provider]?.credentialScopeID == key.credentialScopeID
      else { continue }
      refreshUsageInsightsAfterLocalLogChange(provider: key.provider)
    }
  }
}
