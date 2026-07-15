import QuotariCore

enum ProviderCredentialDiscoveryState {
  case unknown
  case present
  case absent
}

extension UsageStore {
  subscript(providerEnabled provider: UsageProvider) -> Bool {
    get { isProviderEnabled(provider) }
    set { setProviderEnabled(provider, enabled: newValue) }
  }

  var enabledProviderDescriptors: [ProviderDescriptor] {
    providers.filter { isProviderEnabled($0.id) }
  }

  func isProviderEnabled(_ provider: UsageProvider) -> Bool {
    providerActivation.isEnabled(provider)
  }

  func hasDiscoveredCredentials(for provider: UsageProvider) -> Bool {
    providersWithDiscoveredCredentials.contains(provider)
  }

  func credentialDiscoveryState(for provider: UsageProvider) -> ProviderCredentialDiscoveryState {
    guard credentialDiscoveryCompleted.contains(provider) else { return .unknown }
    return hasDiscoveredCredentials(for: provider) ? .present : .absent
  }

  func setProviderEnabled(_ provider: UsageProvider, enabled: Bool) {
    guard providerActivation.setProvider(provider, enabled: enabled) else { return }

    if enabled {
      enqueueQuotaNotificationScopeRestore(for: provider)
      enqueueSelectionRefresh(for: provider, waitingForProviderActivity: true)
    } else {
      disableProvider(provider)
    }
  }

  private func disableProvider(_ provider: UsageProvider) {
    invalidateAccountRevision(for: provider)

    snapshots[provider] = nil
    errors[provider] = nil
    sourceLabels[provider] = nil
    captureErrors[provider] = nil
    accountLoginErrors[provider] = nil
    accountLoginOutputs[provider] = nil
    accountUsage[provider] = nil
    refreshingAccountUsageProviders.remove(provider)

    // The estimator internally uses detached work, so cancellation alone does
    // not mean the scan has stopped. Keep the handle until it drains; a rapid
    // re-enable waits for it before starting the replacement generation.
    cancelCostRefresh(for: provider)
    lastCostScans[provider] = nil
    lastEmptyCostScans[provider] = nil
    latestReportedCostFallbacks[provider] = nil

    selectionRefreshTasks[provider]?.cancel()
    providerFetchTasks[provider]?.task.cancel()
    selectionProviderFetchTasks[provider]?.task.cancel()
    accountUsageRefreshTasks[provider]?.task.cancel()
    quotaNotifications.setActiveLogicalAccountID(nil, for: provider)
    reconcileMenuBarUsageSource()
  }

  func reconcileMenuBarUsageSource() {
    guard case let .provider(provider) = menuBarPreferences.usageSource,
          !isProviderEnabled(provider)
    else { return }
    menuBarPreferences.setUsageSource(.mostConstrained)
  }
}
