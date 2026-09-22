import QuotariCore

extension UsageStore {
  func prepareClaudeCLIRecoveryForReload(_ provider: UsageProvider) async -> [String: String]? {
    guard provider == .claude, automaticallyCapturesDiscoveredAccounts,
          isProviderEnabled(provider), !isSwitching, addingAccountProviders.isEmpty else { return nil }
    let transitions = await drainProviderActivityBeforeCapture(provider)
    if isProviderEnabled(provider), !isSwitching, addingAccountProviders.isEmpty {
      await recoverClaudeCLIIfNeeded()
    }
    return transitions
  }

  /// Runs inside the account-reload capture gate, after existing fetches have
  /// drained. Rediscovery immediately afterwards publishes the repaired source
  /// and hides its saved copy before another usage request can rotate it.
  func recoverClaudeCLIIfNeeded() async {
    let switcher = accountSwitch
    let profiles = claudeProfiles
    let now = currentDate()
    do {
      guard let recovery = try await Task.detached(operation: {
        try switcher.recoverClaudeCLIIfNeeded(profiles: profiles, now: now)
      }).value else { return }
      let liveID = ProviderAccount.id(provider: .claude, source: recovery.source)
      claudeProfiles[liveID] = recovery.profile
      profileFetchAttempts[liveID] = recovery.profile.fingerprint
      try? profileStore.save(claudeProfiles)
      credentialLifecycleLogger.record(
        .automaticCLIRecoverySucceeded,
        provider: .claude,
        source: recovery.source,
        correlationSource: .quotariRegistry(id: recovery.registryID),
        interaction: .background,
        timestamp: now
      )
    } catch AccountSwitchError.cliStillRunning {
      // The next timer pass retries after Claude exits.
    } catch {
      credentialLifecycleLogger.record(
        .automaticCLIRecoveryFailed,
        provider: .claude,
        interaction: .background,
        failure: .classify(error),
        timestamp: now
      )
    }
  }
}
