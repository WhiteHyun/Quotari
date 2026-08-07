import Foundation
import QuotariCore

extension UsageStore {
  /// Claude refresh tokens rotate, so a token fingerprint mismatch does not
  /// necessarily mean a different account. Before creating another registry
  /// row, resolve stable profile identity for the live candidate and every
  /// existing saved Claude account. A proven match refreshes that row in
  /// place; incomplete identity evidence fails closed instead of accumulating
  /// a stale duplicate.
  func automaticCapturePlans(
    for candidates: [ProviderAccount],
    among accounts: [ProviderAccount],
    provider: UsageProvider,
    capturedCopies: [String: ProviderAccount] = [:]
  ) async -> [String: AutomaticAccountCapturePlan] {
    await automaticCapturePlanning(
      for: candidates,
      among: accounts,
      provider: provider,
      capturedCopies: capturedCopies
    ).plans
  }

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
    if let plans = soleClaudeCapturePlans(
      candidates: candidates,
      liveAccounts: liveAccounts,
      savedAccounts: saved
    ) {
      return AutomaticAccountCapturePlanningResult(
        plans: plans,
        verifiedDuplicateCredentialScopeIDs: [],
        credentialTransitions: [:]
      )
    }

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
    var groups: [[ResolvedSavedClaudeProfile]] = []
    for row in profiles {
      if let index = groups.firstIndex(where: { group in
        group.contains { row.profile.identifiesSameAccount(as: $0.profile) }
      }) {
        groups[index].append(row)
      } else {
        groups.append([row])
      }
    }
    var removed = Set<String>()
    for group in groups where group.count > 1 {
      let alive = group.filter { !$0.requiresReauthentication }
      // With two plausibly-live rows there is no proof which one owns the
      // account's refresh-token chain; removal could destroy the only working
      // snapshot, so ambiguity keeps the existing blocked behavior.
      guard alive.count <= 1,
            let canonical = alive.first
              ?? group.max(by: { $0.captured.capturedAt < $1.captured.capturedAt })
      else { continue }
      for row in group
        where row.requiresReauthentication && row.captured.id != canonical.captured.id {
        do {
          try await removeDeadSavedClaudeRow(id: row.captured.id)
          removed.insert(row.captured.id)
        } catch {
          // The row stays in the resolution; planning keeps failing closed for
          // this account exactly as before, and a later scan retries.
        }
      }
    }
    return removed
  }

  private func removeDeadSavedClaudeRow(id: String) async throws {
    let capture = accountCapture
    try await Task.detached { try capture.remove(id: id) }.value
    let savedID = ProviderAccount.id(provider: .claude, source: .quotariRegistry(id: id))
    claudeProfiles[savedID] = nil
    profileFetchAttempts[savedID] = nil
    emptyClaudeProfileFingerprints[savedID] = nil
    try? profileStore.save(claudeProfiles)
  }

  private func verifiedDuplicateClaudeCredentialScopeIDs(
    in profiles: [ResolvedLiveClaudeProfile]
  ) -> Set<String> {
    var canonicalProfiles: [ResolvedLiveClaudeProfile] = []
    var duplicates = Set<String>()
    for candidate in profiles.sorted(by: prefersClaudeCaptureSource) {
      if canonicalProfiles.contains(where: {
        candidate.profile.identifiesSameAccount(as: $0.profile)
      }) {
        duplicates.insert(candidate.account.credentialScopeID)
      } else {
        canonicalProfiles.append(candidate)
      }
    }
    return duplicates
  }

  private func soleClaudeCapturePlans(
    candidates: [ProviderAccount],
    liveAccounts: [ProviderAccount],
    savedAccounts: [CapturedAccount]
  ) -> [String: AutomaticAccountCapturePlan]? {
    guard savedAccounts.isEmpty, liveAccounts.count == 1, let candidate = candidates.first else {
      return nil
    }
    return capturePlans(for: [candidate])
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
    let matchingLiveAccounts = liveProfiles.filter { profile.identifiesSameAccount(as: $0.profile) }
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
    let matchingSaved = savedResolution.profiles.filter { profile.identifiesSameAccount(as: $0.profile) }
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
    let matches = resolution.profiles.filter { profile.identifiesSameAccount(as: $0.profile) }
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

indirect enum AutomaticAccountCapturePlan: Sendable {
  case capture
  case captureClaude(accessTokenFingerprint: String, profile: ClaudeProfile)
  case refreshClaude(
    id: String,
    savedOrigin: ProviderAccount,
    accessTokenFingerprint: String,
    profile: ClaudeProfile
  )
  case ignoreDuplicate(
    savedOrigin: ProviderAccount?,
    canonicalCandidateID: String?,
    fallbackCapturePlan: AutomaticAccountCapturePlan?
  )
  case blocked(String)

  func capture(
    _ account: ProviderAccount,
    using service: AccountCaptureService,
    now: Date
  ) throws -> CapturedAccount? {
    switch self {
    case .capture:
      try service.capture(account, now: now)
    case let .captureClaude(fingerprint, _):
      try service.captureClaudeAccount(
        account,
        expectedAccessTokenFingerprint: fingerprint,
        now: now
      )
    case let .refreshClaude(id, _, fingerprint, _):
      try service.refreshCapturedClaudeAccount(
        id: id,
        from: account,
        expectedAccessTokenFingerprint: fingerprint
      )
    case .ignoreDuplicate:
      nil
    case let .blocked(message):
      throw AutomaticAccountCapturePlanError.blocked(message)
    }
  }

  func savedClaudeIdentity(captured: CapturedAccount?) -> (id: String, profile: ClaudeProfile)? {
    switch self {
    case let .captureClaude(_, profile):
      return captured.map { ($0.id, profile) }
    case let .refreshClaude(id, _, fingerprint, profile):
      guard let captured,
            let accessToken = ProviderCredentialIdentity.discoveredAccountIdentity(
              provider: .claude,
              payload: captured.payload
            ),
            ProviderCredentialIdentity.fingerprint(of: accessToken) == fingerprint
      else { return nil }
      return (id, profile)
    case .capture, .ignoreDuplicate, .blocked:
      return nil
    }
  }

  var isIgnoredDuplicate: Bool {
    if case .ignoreDuplicate = self {
      return true
    }
    return false
  }

  var duplicateSavedOrigin: ProviderAccount? {
    switch self {
    case let .refreshClaude(_, savedOrigin, _, _): savedOrigin
    case let .ignoreDuplicate(savedOrigin, _, _): savedOrigin
    case .capture, .captureClaude, .blocked: nil
    }
  }

  var canonicalCandidateID: String? {
    guard case let .ignoreDuplicate(_, canonicalCandidateID, _) = self else { return nil }
    return canonicalCandidateID
  }

  var fallbackCapturePlan: AutomaticAccountCapturePlan? {
    guard case let .ignoreDuplicate(_, _, fallbackCapturePlan) = self else { return nil }
    return fallbackCapturePlan
  }
}

private enum AutomaticAccountCapturePlanError: LocalizedError {
  case blocked(String)

  var errorDescription: String? {
    guard case let .blocked(message) = self else { return nil }
    return message
  }
}

extension ProviderCredentialSource {
  var isAutomaticallyCapturable: Bool {
    switch self {
    case .codexAuthFile, .codexKeychain, .claudeKeychain, .claudeCredentialsFile:
      true
    case .claudeEnvironment, .quotariRegistry:
      false
    }
  }
}
