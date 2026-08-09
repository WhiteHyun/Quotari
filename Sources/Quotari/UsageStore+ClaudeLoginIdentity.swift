import Foundation
import QuotariCore

extension UsageStore {
  func matchingSavedClaudeAccount(
    for profile: ClaudeProfile,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline? = nil
  ) async throws -> ProviderAccount? {
    guard profile.hasStrongAccountIdentity else { return nil }
    let candidates = savedClaudeLoginCandidates(
      previousClaudeLogin: previousClaudeLogin,
      registryBaseline: registryBaseline
    )
    let matches = try await matchingSavedClaudeLoginAccounts(
      candidates,
      profile: profile,
      previousClaudeLogin: previousClaudeLogin
    )
    return preferredSavedClaudeLoginAccount(
      among: matches,
      previousClaudeLogin: previousClaudeLogin
    )
  }

  private func matchingSavedClaudeLoginAccounts(
    _ candidates: [ProviderAccount],
    profile: ClaudeProfile,
    previousClaudeLogin: PreservedClaudeLogin?
  ) async throws -> [ProviderAccount] {
    var matches: [ProviderAccount] = []
    for candidate in candidates {
      let savedProfile = try await savedClaudeLoginProfile(
        for: candidate,
        previousClaudeLogin: previousClaudeLogin
      )
      if savedProfile.stronglyIdentifiesSameAccount(as: profile) {
        matches.append(candidate)
      }
    }
    return matches
  }

  private func savedClaudeLoginCandidates(
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline?
  ) -> [ProviderAccount] {
    var candidates: [String: ProviderAccount] = [:]
    if let previousClaudeLogin {
      candidates[previousClaudeLogin.account.id] = previousClaudeLogin.account
    }
    for account in accounts[.claude] ?? [] where account.credentialSource.isCaptured {
      candidates[account.id] = account
    }
    for account in capturedEquivalents.values where account.provider == .claude {
      candidates[account.id] = account
    }
    for account in registryBaseline?.registeredProviderAccounts ?? [] where account.provider == .claude {
      candidates[account.id] = account
    }
    return Array(candidates.values)
  }

  private func savedClaudeLoginProfile(
    for candidate: ProviderAccount,
    previousClaudeLogin: PreservedClaudeLogin?
  ) async throws -> ClaudeProfile {
    if candidate.id == previousClaudeLogin?.account.id, let previousClaudeLogin {
      return previousClaudeLogin.profile
    }
    do {
      return try await resolvedClaudeLoginProfile(for: candidate)
    } catch {
      throw AddedAccountImportError.savedRegistryIdentityUnverified
    }
  }

  private func preferredSavedClaudeLoginAccount(
    among matches: [ProviderAccount],
    previousClaudeLogin: PreservedClaudeLogin?
  ) -> ProviderAccount? {
    let referencedIDs = [
      previousClaudeLogin?.account.id,
      persistableSelections()[.claude]?.id,
      reconciledSelectionOrigins[.claude]?.id,
    ].compactMap(\.self)
    for id in referencedIDs {
      if let referenced = matches.first(where: { $0.id == id }) {
        return referenced
      }
    }
    // Multiple rows with the same strong account-and-organization identity
    // are stale credential generations of one logical account. Refresh one
    // deterministic row first; the normal reload healer can then remove only
    // the generations that OAuth definitively rejects.
    return matches.min(by: { $0.id < $1.id })
  }

  func refreshReauthenticatedClaudeAccount(
    _ saved: ProviderAccount,
    payload: Data,
    profile: ClaudeProfile?,
    claudeOAuthAccount: Data? = nil,
    requiresNewerGenerationEvidence: Bool = false
  ) async throws -> CapturedAccount {
    guard case let .quotariRegistry(id) = saved.credentialSource else {
      throw AddedAccountImportError.savedCopyUnverified
    }
    let capture = accountCapture
    let captured = try await Task.detached {
      try capture.refreshCapturedAccount(
        id: id,
        provider: .claude,
        payload: payload,
        claudeOAuthAccount: claudeOAuthAccount,
        claudeAccountIdentity: profile?.accountIdentity,
        requiresNewerGenerationEvidence: requiresNewerGenerationEvidence
      )
    }.value
    if let profile {
      storeClaudeLoginProfile(profile, for: captured)
    }
    return captured
  }

  func storeClaudeLoginProfile(_ profile: ClaudeProfile, for captured: CapturedAccount) {
    storeClaudeLoginProfile(profile, accountID: captured.providerAccount.id)
  }

  private func storeClaudeLoginProfile(_ profile: ClaudeProfile, accountID: String) {
    claudeProfiles[accountID] = profile
    profileFetchAttempts[accountID] = profile.fingerprint
    emptyClaudeProfileFingerprints[accountID] = nil
    try? profileStore.save(claudeProfiles)
  }

  func resolvedClaudeLoginProfile(for saved: ProviderAccount) async throws -> ClaudeProfile {
    let loader = claudeCredentialLoader
    guard let credentials = await Task.detached(operation: {
      loader(saved.credentialSource)
    }).value else {
      throw AddedAccountImportError.savedIdentityUnverified
    }
    let fingerprint = ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
    let persistedIdentity = await persistedClaudeAccountIdentity(for: saved)
    if let cached = claudeProfiles[saved.id],
       cached.hasStableAccountIdentity,
       cached.fingerprint == fingerprint {
      if let persistedIdentity, persistedIdentity.isStrong {
        return profileApplyingPersistedIdentity(cached, identity: persistedIdentity)
      }
      return cached
    }
    if let persistedIdentity, persistedIdentity.isStrong {
      return profileApplyingPersistedIdentity(
        ClaudeProfile(fingerprint: fingerprint),
        identity: persistedIdentity
      )
    }
    let fetched = try await profileFetcher.fetchProfile(accessToken: credentials.accessToken)
    guard fetched.hasStableAccountIdentity,
          let current = await Task.detached(operation: {
            loader(saved.credentialSource)
          }).value,
          ProviderCredentialIdentity.fingerprint(of: current.accessToken) == fingerprint
    else { throw AddedAccountImportError.savedIdentityUnverified }
    let verified = fetched.verified(for: fingerprint)
    storeClaudeLoginProfile(verified, accountID: saved.id)
    return verified
  }

  private func persistedClaudeAccountIdentity(
    for saved: ProviderAccount
  ) async -> ClaudeAccountIdentity? {
    guard case let .quotariRegistry(id) = saved.credentialSource else { return nil }
    let capture = accountCapture
    return await Task.detached {
      capture.captured().first(where: { $0.id == id })?.claudeAccountIdentity
    }.value
  }
}
