import Foundation
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
    let selected = reconciledSelectionOrigins[.claude] == nil ? selectedAccounts[.claude] : nil
    let now = currentDate()
    let recoveryTask = Task.detached {
      try switcher.recoverClaudeCLIIfNeeded(profiles: profiles, now: now, selectedAccount: selected)
    }
    // Retain the cancelled task until it drains: re-enabling monitoring must
    // not revive an operation that was already stopped by the user's toggle.
    claudeCLIRecoveryTask = recoveryTask
    defer { claudeCLIRecoveryTask = nil }
    do {
      let result = try await withTaskCancellationHandler {
        try await recoveryTask.value
      } onCancel: {
        recoveryTask.cancel()
      }
      guard let recovery = result else { return [:] }
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
      return preservePartialClaudeRecovery(failure, originalProfiles: profiles, now: now)
    } catch is CancellationError {
      // Disabling monitoring stops recovery at the next mutation boundary.
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

  private func preservePartialClaudeRecovery(
    _ failure: ClaudeCLIRecoveryFailure,
    originalProfiles: [String: ClaudeProfile],
    now: Date
  ) -> [String: String] {
    // Keep proof for a stale hidden mirror before profile refresh advances
    // the canonical slot's cache. Never replace a profile updated meanwhile.
    for (id, profile) in failure.verifiedProfiles where claudeProfiles[id] == originalProfiles[id] {
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
    return failure.credentialTransitions
  }
}
