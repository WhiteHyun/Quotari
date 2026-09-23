import QuotariCore

extension UsageStore {
  func prepareClaudeCLIRecoveryForReload(_ provider: UsageProvider) async -> [String: String]? {
    guard provider == .claude, automaticallyCapturesDiscoveredAccounts,
          isProviderEnabled(provider), !isSwitching, addingAccountProviders.isEmpty else { return nil }
    let transitions = await drainProviderActivityBeforeCapture(provider)
    if isProviderEnabled(provider), !isSwitching, addingAccountProviders.isEmpty {
      let recoveryTransitions = await recoverClaudeCLIIfNeeded()
      return mergedCredentialTransitions(transitions, recoveryTransitions)
    }
    return transitions
  }

  /// Runs inside the account-reload capture gate, after existing fetches have
  /// drained. Rediscovery immediately afterwards publishes the repaired source
  /// and hides its saved copy before another usage request can rotate it.
  func recoverClaudeCLIIfNeeded() async -> [String: String] {
    let switcher = accountSwitch
    let profiles = claudeProfiles
    let now = currentDate()
    do {
      guard let recovery = try await Task.detached(operation: {
        try switcher.recoverClaudeCLIIfNeeded(profiles: profiles, now: now)
      }).value else { return [:] }
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
      return recovery.credentialTransitions
    } catch let failure as ClaudeCLIRecoveryFailure {
      // Keep proof for a stale hidden mirror before profile refresh advances
      // the canonical slot's cache. Never replace a profile updated meanwhile.
      for (id, profile) in failure.verifiedProfiles where claudeProfiles[id] == profiles[id] {
        claudeProfiles[id] = profile
      }
      try? profileStore.save(claudeProfiles)
      credentialLifecycleLogger.record(
        .automaticCLIRecoveryFailed,
        provider: .claude,
        interaction: .background,
        failure: .classify(failure.underlying),
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
    return [:]
  }
}
