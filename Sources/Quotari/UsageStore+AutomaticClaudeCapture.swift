import Foundation
import QuotariCore

extension UsageStore {
  /// Claude refresh tokens rotate, so a token fingerprint mismatch does not
  /// necessarily mean a different account. Before creating another registry
  /// row, resolve stable profile identity for the live candidate and every
  /// existing saved Claude account. A proven match refreshes that row in
  /// place; incomplete identity evidence fails closed instead of accumulating
  /// a stale duplicate.
  func automaticCapturePlanning(
    for candidates: [ProviderAccount],
    among accounts: [ProviderAccount],
    provider: UsageProvider,
    capturedCopies: [String: ProviderAccount] = [:]
  ) async -> AutomaticAccountCapturePlanningResult {
    guard provider == .claude else {
      return AutomaticAccountCapturePlanningResult(
        plans: capturePlans(for: candidates),
        verifiedDuplicateCredentialScopeIDs: [],
        credentialTransitions: [:]
      )
    }
    return await automaticClaudeCapturePlanning(
      for: candidates,
      among: accounts,
      capturedCopies: capturedCopies
    )
  }

  private func automaticClaudeCapturePlanning(
    for candidates: [ProviderAccount],
    among accounts: [ProviderAccount],
    capturedCopies: [String: ProviderAccount]
  ) async -> AutomaticAccountCapturePlanningResult {
    let saved = await savedClaudeAccounts()
    let liveAccounts = accounts.filter(\.credentialSource.isAutomaticallyCapturable)
    let savedResolution = await healedSavedClaudeProfileResolution(
      resolvedSavedClaudeProfiles(saved)
    )
    let liveResolution = await resolvedLiveClaudeProfiles(
      liveAccounts,
      capturedCopies: capturedCopies
    )
    let liveProfiles = liveResolution.profiles
    let plans = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
      let plan = claudeCapturePlan(
        for: candidate,
        candidates: candidates,
        liveProfiles: liveProfiles,
        savedResolution: savedResolution
      )
      return (candidate.id, plan)
    })
    return AutomaticAccountCapturePlanningResult(
      plans: plans,
      verifiedDuplicateCredentialScopeIDs: verifiedDuplicateClaudeCredentialScopeIDs(in: liveProfiles),
      credentialTransitions: liveResolution.credentialTransitions
    )
  }

  /// Registry hygiene for verified duplicates: two saved rows proven to be the
  /// same account can never both stay renewable — the account has one rotating
  /// refresh-token chain, so at most one row can hold it. When all but one of
  /// the duplicates are provably dead (their stored refresh token was rejected
  /// as an invalid grant this scan), remove the dead rows and keep a single
  /// canonical row for the normal refresh plan to converge on. Two duplicates
  /// that are both plausibly alive remain ambiguous and keep failing closed.
  private func healedSavedClaudeProfileResolution(
    _ resolution: SavedClaudeProfileResolution
  ) async -> SavedClaudeProfileResolution {
    let removedIDs = await removedDeadDuplicateSavedClaudeRowIDs(resolution.profiles)
    guard !removedIDs.isEmpty else { return resolution }
    return SavedClaudeProfileResolution(
      profiles: resolution.profiles.filter { !removedIDs.contains($0.captured.id) },
      hasUnresolvedProfile: resolution.hasUnresolvedProfile
    )
  }

  private func removedDeadDuplicateSavedClaudeRowIDs(
    _ profiles: [ResolvedSavedClaudeProfile]
  ) async -> Set<String> {
    var groups: [ClaudeAccountIdentity.Key: [ResolvedSavedClaudeProfile]] = [:]
    for row in profiles {
      guard let identity = row.profile.accountIdentity,
            identity.isStrong,
            let key = identity.key
      else { continue }
      groups[key, default: []].append(row)
    }
    var removed = Set<String>()
    for group in groups.values where group.count > 1 {
      let alive = group.filter { !$0.requiresReauthentication }
      // With two plausibly-live rows there is no proof which one owns the
      // account's refresh-token chain; removal could destroy the only working
      // snapshot, so ambiguity keeps the existing blocked behavior.
      // An all-dead group is consolidated only after a live credential has
      // successfully refreshed the chosen canonical row. Planning must never
      // delete every fallback before that write succeeds.
      guard alive.count == 1, let canonical = alive.first else { continue }
      for row in group
        where row.requiresReauthentication && row.captured.id != canonical.captured.id {
        do {
          try await consolidateDeadSavedClaudeRow(row.captured, into: canonical.captured)
          removed.insert(row.captured.id)
        } catch {
          // The row stays in the resolution; planning keeps failing closed for
          // this account exactly as before, and a later scan retries.
        }
      }
    }
    return removed
  }

  func consolidateDeadSavedClaudeRow(
    _ redundant: CapturedAccount,
    into canonical: CapturedAccount
  ) async throws {
    try migrateClaudeRegistryReferences(
      from: redundant.providerAccount,
      to: canonical.providerAccount
    )
    let capture = accountCapture
    try await Task.detached { try capture.remove(id: redundant.id) }.value
    let savedID = redundant.providerAccount.id
    claudeProfiles[savedID] = nil
    profileFetchAttempts[savedID] = nil
    emptyClaudeProfileFingerprints[savedID] = nil
    try? profileStore.save(claudeProfiles)
  }

  /// Durable references move before the old Keychain row is deleted. If either
  /// atomic JSON write fails, the old row remains and the next scan retries.
  private func migrateClaudeRegistryReferences(
    from redundant: ProviderAccount,
    to canonical: ProviderAccount
  ) throws {
    guard isMonitoringConfigurationLoaded else {
      throw ClaudeRegistryReferenceMigrationError.monitoringConfigurationUnavailable
    }

    var selections = persistableSelections()
    if selections[.claude]?.id == redundant.id {
      selections[.claude] = canonical
    }

    var monitoring = persistedMonitoredAccounts
    let monitoringChanged = monitoring[.claude]?.contains(where: { $0.id == redundant.id }) == true
    if monitoringChanged {
      monitoring[.claude] = replacingAccount(
        redundant,
        with: canonical,
        in: monitoring[.claude] ?? []
      )
    }

    // A prior failed scan may already have reconciled the in-memory references
    // to `canonical` while the durable files still name `redundant`. Rewrite
    // both complete maps on every retry so memory can never mask that debt.
    try accountSelectionStore.save(selections)
    try accountMonitoringStore.save(monitoring)

    if selectedAccounts[.claude]?.id == redundant.id {
      selectAccount(
        canonical,
        for: .claude,
        standingInFor: nil,
        refreshInteraction: .background,
        cancelsDelayedCredentialRefresh: false,
        waitsForDelayedCredentialRefresh: true
      )
    } else if reconciledSelectionOrigins[.claude]?.id == redundant.id {
      selectAccount(
        selectedAccounts[.claude],
        for: .claude,
        standingInFor: canonical,
        refreshInteraction: .background,
        cancelsDelayedCredentialRefresh: false,
        waitsForDelayedCredentialRefresh: true
      )
    }
    persistedMonitoredAccounts = monitoring
    isMonitoringConfigurationLoaded = true
    monitoredAccounts[.claude] = replacingAccount(
      redundant,
      with: canonical,
      in: monitoredAccounts[.claude] ?? []
    )
    capturedEquivalents = capturedEquivalents.mapValues {
      $0.id == redundant.id ? canonical : $0
    }
    accountUsage[.claude]?[redundant.id] = nil
    notificationScopeIDsByAccountID[redundant.id] = nil
    accountRevisions[.claude, default: 0] &+= 1
  }

  private func replacingAccount(
    _ redundant: ProviderAccount,
    with canonical: ProviderAccount,
    in accounts: [ProviderAccount]
  ) -> [ProviderAccount] {
    var seen = Set<String>()
    return accounts.compactMap { account in
      let replacement = account.id == redundant.id ? canonical : account
      return seen.insert(replacement.id).inserted ? replacement : nil
    }
  }

  private func verifiedDuplicateClaudeCredentialScopeIDs(
    in profiles: [ResolvedLiveClaudeProfile]
  ) -> Set<String> {
    var canonicalProfiles: [ResolvedLiveClaudeProfile] = []
    var duplicates = Set<String>()
    for candidate in profiles.sorted(by: prefersClaudeCaptureSource) {
      if canonicalProfiles.contains(where: {
        candidate.profile.stronglyIdentifiesSameAccount(as: $0.profile)
      }) {
        duplicates.insert(candidate.account.credentialScopeID)
      } else {
        canonicalProfiles.append(candidate)
      }
    }
    return duplicates
  }

  private func claudeCapturePlan(
    for candidate: ProviderAccount,
    candidates: [ProviderAccount],
    liveProfiles: [ResolvedLiveClaudeProfile],
    savedResolution: SavedClaudeProfileResolution
  ) -> AutomaticAccountCapturePlan {
    guard let candidateProfile = liveProfiles.first(where: { $0.account.id == candidate.id }) else {
      return .blocked("Couldn’t verify this Claude account before managing it.")
    }
    let profile = candidateProfile.profile
    if !profile.hasStrongAccountIdentity {
      guard candidateProfile.isRenewable, let fingerprint = profile.fingerprint else {
        return .blocked("Couldn’t verify this Claude account before managing it.")
      }
      return .captureClaude(
        accessTokenFingerprint: fingerprint,
        profile: profile
      )
    }
    let matchingLiveAccounts = liveProfiles.filter { profile.stronglyIdentifiesSameAccount(as: $0.profile) }
    let canonical = matchingLiveAccounts.min(by: prefersClaudeCaptureSource)
    guard canonical?.account.id != candidate.id else {
      return claudeSavedAccountPlan(
        profile: profile,
        resolution: savedResolution,
        isRenewable: candidateProfile.isRenewable
      )
    }
    return duplicateClaudeCapturePlan(
      profile: profile,
      isRenewable: candidateProfile.isRenewable,
      canonical: canonical?.account,
      candidates: candidates,
      savedResolution: savedResolution
    )
  }

  private func duplicateClaudeCapturePlan(
    profile: ClaudeProfile,
    isRenewable: Bool,
    canonical: ProviderAccount?,
    candidates: [ProviderAccount],
    savedResolution: SavedClaudeProfileResolution
  ) -> AutomaticAccountCapturePlan {
    let matchingSaved = savedResolution.profiles.filter {
      profile.stronglyIdentifiesSameAccount(as: $0.profile)
    }
    if matchingSaved.count == 1, let saved = matchingSaved.first?.captured.providerAccount {
      return .ignoreDuplicate(
        savedOrigin: saved,
        canonicalCandidateID: nil,
        fallbackCapturePlan: nil
      )
    }
    if matchingSaved.count > 1 {
      return .blocked("Multiple saved Claude accounts have the same verified profile.")
    }
    if candidates.contains(where: { $0.id == canonical?.id }) {
      return .ignoreDuplicate(
        savedOrigin: nil,
        canonicalCandidateID: canonical?.id,
        fallbackCapturePlan: claudeSavedAccountPlan(
          profile: profile,
          resolution: savedResolution,
          isRenewable: isRenewable
        )
      )
    }
    return .blocked("Couldn’t verify the saved copy for this Claude account.")
  }

  private func capturePlans(for candidates: [ProviderAccount]) -> [String: AutomaticAccountCapturePlan] {
    Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, .capture) })
  }

  private func claudeSavedAccountPlan(
    profile: ClaudeProfile,
    resolution: SavedClaudeProfileResolution,
    isRenewable: Bool
  ) -> AutomaticAccountCapturePlan {
    guard let fingerprint = profile.fingerprint else {
      return .blocked("Couldn’t verify this Claude account before managing it.")
    }
    let matches = resolution.profiles.filter {
      profile.stronglyIdentifiesSameAccount(as: $0.profile)
    }
    if matches.count == 1, let match = matches.first {
      guard isRenewable else {
        return .ignoreDuplicate(
          savedOrigin: match.captured.providerAccount,
          canonicalCandidateID: nil,
          fallbackCapturePlan: nil
        )
      }
      return .refreshClaude(
        id: match.captured.id,
        savedOrigin: match.captured.providerAccount,
        accessTokenFingerprint: fingerprint,
        profile: profile
      )
    }
    if matches.count > 1 {
      let alive = matches.filter { !$0.requiresReauthentication }
      if alive.isEmpty, isRenewable,
         let canonical = matches.max(by: { $0.captured.capturedAt < $1.captured.capturedAt }) {
        return .refreshClaude(
          id: canonical.captured.id,
          savedOrigin: canonical.captured.providerAccount,
          accessTokenFingerprint: fingerprint,
          profile: profile,
          redundantAccounts: matches
            .filter { $0.captured.id != canonical.captured.id }
            .map(\.captured)
        )
      }
      return .blocked("Multiple saved Claude accounts have the same verified profile.")
    }
    if resolution.hasUnresolvedProfile {
      return .blocked("Couldn’t verify every saved Claude account before managing this login.")
    }
    return .captureClaude(
      accessTokenFingerprint: fingerprint,
      profile: profile
    )
  }

  private func prefersClaudeCaptureSource(
    _ lhs: ResolvedLiveClaudeProfile,
    _ rhs: ResolvedLiveClaudeProfile
  ) -> Bool {
    if lhs.isRenewable != rhs.isRenewable {
      return lhs.isRenewable
    }
    return claudeAutomaticCaptureRank(lhs.account.credentialSource)
      < claudeAutomaticCaptureRank(rhs.account.credentialSource)
  }

  private func claudeAutomaticCaptureRank(_ source: ProviderCredentialSource) -> Int {
    switch source {
    case .claudeKeychain: 0
    case .claudeCredentialsFile: 1
    case .codexAuthFile, .codexKeychain, .claudeEnvironment, .quotariRegistry: 2
    }
  }
}

private enum ClaudeRegistryReferenceMigrationError: Error {
  case monitoringConfigurationUnavailable
}
