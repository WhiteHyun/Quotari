import Foundation
import QuotariCore

extension UsageStore {
  /// Every renewable account discovered in a CLI-owned slot is managed by
  /// Quotari automatically. Existing saved identities are excluded by the
  /// caller; failures remain isolated per account so one unreadable slot does
  /// not prevent the rest of the provider's accounts from being registered.
  /// Returns the exact saved identities produced for the discovery snapshot.
  func automaticallyCaptureDiscoveredAccounts(
    _ accounts: [ProviderAccount],
    excluding capturedCopies: [String: ProviderAccount],
    provider: UsageProvider
  ) async -> AutomaticAccountCaptureResult {
    let candidates = accounts.filter { account in
      capturedCopies[account.id] == nil && account.credentialSource.isAutomaticallyCapturable
    }
    guard !candidates.isEmpty else {
      captureErrors[provider] = nil
      return .none
    }

    let drainedCredentialTransitions = await drainProviderActivityBeforeCapture(provider)
    let planning = await automaticCapturePlanning(
      for: candidates,
      among: accounts,
      provider: provider
    )
    let credentialTransitions = mergedCredentialTransitions(
      drainedCredentialTransitions,
      planning.credentialTransitions
    )
    let outcomes = await automaticCaptureOutcomes(
      candidates,
      plans: planning.plans,
      drainedCredentialTransitions: credentialTransitions
    )
    recordCapturedClaudeProfiles(from: outcomes)
    let failures = outcomes.compactMap { outcome in
      outcome.error.map { "Couldn’t manage “\(outcome.account.displayName)” automatically: \($0)" }
    }
    captureErrors[provider] = failures.isEmpty ? nil : failures.joined(separator: "\n")
    return AutomaticAccountCaptureResult(
      selectionOrigins: outcomes.reduce(into: [:]) { origins, outcome in
        guard let origin = outcome.selectionOrigin else { return }
        origins[outcome.account.credentialScopeID] = origin
        // If Quotari finished rotating the selected credential immediately
        // before discovery, the candidate already carries the target scope.
        // Link the persisted source scope to the same managed origin so the
        // normal selection reconciliation can follow that proven A -> B move.
        for (sourceScopeID, targetScopeID) in drainedCredentialTransitions
          where targetScopeID == outcome.account.credentialScopeID {
          origins[sourceScopeID] = origin
        }
      },
      managedCopies: outcomes.reduce(into: [:]) { copies, outcome in
        guard let origin = outcome.selectionOrigin else { return }
        copies[outcome.account.credentialScopeID] = origin
      },
      credentialTransitions: credentialTransitions,
      verifiedDuplicateCredentialScopeIDs: planning.verifiedDuplicateCredentialScopeIDs,
      didCapture: outcomes.contains { $0.captured != nil },
      attempted: true
    )
  }

  private func drainProviderActivityBeforeCapture(_ provider: UsageProvider) async -> [String: String] {
    // Close the provider gate before observing current fetch handles. Any fetch
    // already registered drains first; a later fetch waits for the enclosing
    // account reload to publish the new registry mapping.
    automaticallyCapturingProviders.insert(provider)
    let providerFetch = providerFetchTasks[provider]
    let selectionFetch = selectionProviderFetchTasks[provider]
    let accountUsageRefresh = accountUsageRefreshTasks[provider]
    let selectedCredentialScopeID = selectedAccounts[provider]?.credentialScopeID
    _ = await providerFetch?.task.value
    _ = await selectionFetch?.task.value
    _ = await accountUsageRefresh?.task.value
    // Each task records its transition before completing, so this also covers
    // a fetch whose handle was already cleared immediately before the scan.
    let completedTransitions = completedCredentialTransitions.removeValue(forKey: provider) ?? [:]
    guard provider == .claude, let selectedCredentialScopeID else { return [:] }

    let unambiguousTransitions = completedTransitions.reduce(into: [String: String]()) { result, transition in
      guard transition.value.count == 1, let target = transition.value.first else { return }
      result[transition.key] = target
    }
    let resolvedTransitions = mergedCredentialTransitions(unambiguousTransitions)
    guard let finalScopeID = resolvedTransitions[selectedCredentialScopeID] else { return [:] }
    return [selectedCredentialScopeID: finalScopeID]
  }

  func mergedCredentialTransitions(
    _ transitionMaps: [String: String]...
  ) -> [String: String] {
    var targetsBySource: [String: Set<String>] = [:]
    for transitions in transitionMaps {
      for (source, target) in transitions {
        targetsBySource[source, default: []].insert(target)
      }
    }
    return targetsBySource.keys.reduce(into: [:]) { resolved, source in
      var visited = Set([source])
      var current = source
      while let targets = targetsBySource[current] {
        guard targets.count == 1, let target = targets.first,
              visited.insert(target).inserted
        else { return }
        current = target
      }
      if current != source {
        resolved[source] = current
      }
    }
  }

  private func automaticCaptureOutcomes(
    _ candidates: [ProviderAccount],
    plans: [String: AutomaticAccountCapturePlan],
    drainedCredentialTransitions: [String: String]
  ) async -> [AutomaticAccountCaptureOutcome] {
    let capture = accountCapture
    let now = Date()
    return await Task.detached {
      var capturedByCandidateID: [String: CapturedAccount] = [:]
      var outcomeIndexByCandidateID: [String: Int] = [:]
      var outcomes: [AutomaticAccountCaptureOutcome] = []
      let ordered = candidates.sorted { lhs, rhs in
        let left = plans[lhs.id]?.isIgnoredDuplicate == true
        let right = plans[rhs.id]?.isIgnoredDuplicate == true
        return !left && right
      }
      for account in ordered {
        let plan = plans[account.id] ?? .capture
        let canonicalCapture = plan.canonicalCandidateID.flatMap { capturedByCandidateID[$0] }
        let effectivePlan = canonicalCapture == nil ? (plan.fallbackCapturePlan ?? plan) : plan
        let duplicateOrigin = plan.duplicateSavedOrigin ?? canonicalCapture?.providerAccount
        let outcome = AutomaticAccountCaptureOutcome.capture(
          account,
          plan: effectivePlan,
          selectionEvidence: AutomaticSelectionOriginEvidence(
            override: duplicateOrigin,
            drainedCredentialTransitionTarget: drainedCredentialTransitions[account.credentialScopeID]
          ),
          using: capture,
          now: now
        )
        if let captured = outcome.captured {
          capturedByCandidateID[account.id] = captured
          if let canonicalID = plan.canonicalCandidateID,
             plan.fallbackCapturePlan != nil {
            // This source successfully stood in for the preferred source. Map
            // the canonical row to the same managed account and suppress its
            // now-recovered capture error; later duplicates also reuse it.
            capturedByCandidateID[canonicalID] = captured
            if let canonicalIndex = outcomeIndexByCandidateID[canonicalID] {
              outcomes[canonicalIndex] = outcomes[canonicalIndex]
                .resolvedByFallback(captured.providerAccount)
            }
          }
        }
        outcomeIndexByCandidateID[account.id] = outcomes.count
        outcomes.append(outcome)
      }
      return outcomes
    }.value
  }

  private func recordCapturedClaudeProfiles(from outcomes: [AutomaticAccountCaptureOutcome]) {
    var changed = false
    for outcome in outcomes {
      guard let captured = outcome.captured, captured.provider == .claude else { continue }
      let registryID = outcome.refreshedClaudeRegistryID ?? captured.id
      let profile = outcome.verifiedClaudeProfile
        ?? cachedClaudeProfile(for: outcome.account, matching: captured.payload)
      guard let profile else { continue }
      let savedID = ProviderAccount.id(provider: .claude, source: .quotariRegistry(id: registryID))
      claudeProfiles[savedID] = profile
      profileFetchAttempts[savedID] = profile.fingerprint
      emptyClaudeProfileFingerprints[savedID] = nil
      changed = true
    }
    if changed {
      try? profileStore.save(claudeProfiles)
    }
  }

  private func cachedClaudeProfile(
    for account: ProviderAccount,
    matching capturedPayload: Data
  ) -> ClaudeProfile? {
    guard let profile = claudeProfiles[account.id],
          let fingerprint = profile.fingerprint,
          let accessToken = ProviderCredentialIdentity.discoveredAccountIdentity(
            provider: .claude,
            payload: capturedPayload
          ),
          ProviderCredentialIdentity.fingerprint(of: accessToken) == fingerprint
    else { return nil }
    return profile
  }
}

struct AutomaticAccountCaptureResult: Sendable {
  static let none = AutomaticAccountCaptureResult(
    selectionOrigins: [:],
    managedCopies: [:],
    credentialTransitions: [:],
    verifiedDuplicateCredentialScopeIDs: [],
    didCapture: false,
    attempted: false
  )

  let selectionOrigins: [String: ProviderAccount]
  /// Stable-profile links keyed by the exact discovery-time credential scope.
  /// A post-capture rediscovery may reuse the source id for another login, so
  /// only an unchanged scope may inherit the managed saved account.
  let managedCopies: [String: ProviderAccount]
  /// Exact credential-scope moves that Quotari itself completed while the
  /// scan was in progress. Keeping these separate from saved origins lets a
  /// failed registry write still advance a selected live row, but only when
  /// rediscovery observes the proven target generation.
  let credentialTransitions: [String: String]
  let verifiedDuplicateCredentialScopeIDs: Set<String>
  let didCapture: Bool
  let attempted: Bool
}

struct AutomaticAccountCapturePlanningResult {
  let plans: [String: AutomaticAccountCapturePlan]
  let verifiedDuplicateCredentialScopeIDs: Set<String>
  let credentialTransitions: [String: String]
}

private struct AutomaticAccountCaptureOutcome: Sendable {
  let account: ProviderAccount
  let captured: CapturedAccount?
  let error: String?
  let refreshedClaudeRegistryID: String?
  let verifiedClaudeProfile: ClaudeProfile?
  let selectionOriginOverride: ProviderAccount?
  let drainedCredentialTransitionTarget: String?

  static func capture(
    _ account: ProviderAccount,
    plan: AutomaticAccountCapturePlan,
    selectionEvidence: AutomaticSelectionOriginEvidence,
    using capture: AccountCaptureService,
    now: Date
  ) -> Self {
    do {
      let captured = try plan.capture(account, using: capture, now: now)
      let refreshed = plan.savedClaudeIdentity(captured: captured)
      return Self(
        account: account,
        captured: captured,
        error: nil,
        refreshedClaudeRegistryID: refreshed?.id,
        verifiedClaudeProfile: refreshed?.profile,
        selectionOriginOverride: selectionEvidence.override,
        drainedCredentialTransitionTarget: selectionEvidence.drainedCredentialTransitionTarget
      )
    } catch {
      return Self(
        account: account,
        captured: nil,
        error: error.localizedDescription,
        refreshedClaudeRegistryID: nil,
        verifiedClaudeProfile: nil,
        // Planning may already have proven that this login belongs to an
        // existing saved account, and provider activity may already have
        // installed a new credential generation. A registry failure must not
        // discard either piece of selection evidence.
        selectionOriginOverride: selectionEvidence.override,
        drainedCredentialTransitionTarget: selectionEvidence.drainedCredentialTransitionTarget
      )
    }
  }

  /// The registry row is a valid origin for the discovery-time live row only
  /// when capture re-read the same credential identity. A CLI slot that changed
  /// before the read must not make the old selection claim the new account.
  var selectionOrigin: ProviderAccount? {
    if let selectionOriginOverride {
      return selectionOriginOverride
    }
    guard let captured,
          let identity = ProviderCredentialIdentity.discoveredAccountIdentity(
            provider: captured.provider,
            payload: captured.payload
          )
    else { return nil }
    let capturedLiveIdentity = ProviderAccount(
      provider: account.provider,
      displayName: captured.displayName,
      detail: account.detail,
      credentialSource: account.credentialSource,
      credentialIdentity: identity
    )
    guard capturedLiveIdentity.credentialScopeID == account.credentialScopeID else {
      // A fetch that began with this exact selected credential may rotate its
      // token pair before capture reads the slot. The tracked fetch generation
      // is explicit transition evidence; without it, a changed scope remains
      // an unrelated external login and must not inherit the selection.
      return capturedLiveIdentity.credentialScopeID == drainedCredentialTransitionTarget
        ? captured.providerAccount
        : nil
    }
    return captured.providerAccount
  }

  func resolvedByFallback(_ origin: ProviderAccount) -> Self {
    Self(
      account: account,
      captured: nil,
      error: nil,
      refreshedClaudeRegistryID: nil,
      verifiedClaudeProfile: nil,
      selectionOriginOverride: origin,
      drainedCredentialTransitionTarget: nil
    )
  }
}

private struct AutomaticSelectionOriginEvidence: Sendable {
  let override: ProviderAccount?
  let drainedCredentialTransitionTarget: String?
}

extension CapturedAccount {
  var providerAccount: ProviderAccount {
    ProviderAccount(
      provider: provider,
      displayName: displayName,
      detail: detail ?? "Saved in Quotari",
      credentialSource: .quotariRegistry(id: id)
    )
  }
}
