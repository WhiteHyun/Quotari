import Foundation
import QuotariCore

extension UsageStore {
  func savedClaudeAccounts() async -> [CapturedAccount] {
    let capture = accountCapture
    return await Task.detached {
      capture.captured().filter { $0.provider == .claude }
    }.value
  }

  func resolvedSavedClaudeProfiles(
    _ accounts: [CapturedAccount]
  ) async -> SavedClaudeProfileResolution {
    var profiles: [ResolvedSavedClaudeProfile] = []
    var hasUnresolvedProfile = false
    for captured in accounts {
      guard let resolution = await resolvedClaudeCaptureProfile(
        for: captured.providerAccount,
        persistedIdentity: captured.claudeAccountIdentity
      ) else {
        if await unresolvedSavedClaudeProfileShouldBlock(captured.providerAccount) {
          hasUnresolvedProfile = true
        }
        continue
      }
      switch await resolvedSavedClaudeProfileOutcome(captured, resolution: resolution) {
      case let .resolved(profile):
        profiles.append(profile)
      case .unresolved:
        hasUnresolvedProfile = true
      case .ignored:
        break
      }
    }
    return SavedClaudeProfileResolution(
      profiles: profiles,
      hasUnresolvedProfile: hasUnresolvedProfile
    )
  }

  private func resolvedSavedClaudeProfileOutcome(
    _ captured: CapturedAccount,
    resolution: ClaudeCaptureProfileResolution
  ) async -> ResolvedSavedClaudeProfileOutcome {
    if let profile = resolution.profile, let identity = profile.accountIdentity {
      let identified: CapturedAccount
      if captured.claudeAccountIdentity == identity {
        identified = captured
      } else {
        let capture = accountCapture
        guard let persisted = try? await Task.detached(operation: {
          try capture.recordClaudeAccountIdentity(id: captured.id, identity: identity)
        }).value else { return .unresolved }
        identified = persisted
      }
      return .resolved(ResolvedSavedClaudeProfile(
        captured: identified,
        profile: profileApplyingPersistedIdentity(
          profile,
          identity: identified.claudeAccountIdentity ?? identity
        ),
        requiresReauthentication: resolution.requiresReauthentication
      ))
    }
    if let identity = captured.claudeAccountIdentity, identity.isStrong {
      return .resolved(ResolvedSavedClaudeProfile(
        captured: captured,
        profile: profileApplyingPersistedIdentity(
          ClaudeProfile(fingerprint: resolution.accessTokenFingerprint),
          identity: identity
        ),
        requiresReauthentication: resolution.requiresReauthentication
      ))
    }
    return await unresolvedSavedClaudeProfileShouldBlock(captured.providerAccount)
      ? .unresolved
      : .ignored
  }

  func resolvedLiveClaudeProfiles(
    _ accounts: [ProviderAccount],
    capturedCopies: [String: ProviderAccount] = [:]
  ) async -> LiveClaudeProfileResolution {
    var profiles: [ResolvedLiveClaudeProfile] = []
    var credentialTransitions: [String: String] = [:]
    for account in accounts {
      let capturedRegistryID: String? = if case let .quotariRegistry(id) =
        capturedCopies[account.id]?.credentialSource {
        id
      } else {
        nil
      }
      if let resolution = await resolvedClaudeCaptureProfile(
        for: account,
        capturedRegistryID: capturedRegistryID
      ) {
        if let transition = resolution.credentialTransition {
          credentialTransitions[transition.sourceScopeID] = transition.targetScopeID
        }
        guard let profile = resolution.profile else { continue }
        let loader = claudeCredentialLoader
        let isRenewable = await Task.detached {
          guard let refreshToken = loader(account.credentialSource)?.refreshToken else { return false }
          return !refreshToken.isEmpty
        }.value
        profiles.append(ResolvedLiveClaudeProfile(
          account: account,
          profile: profile,
          isRenewable: isRenewable
        ))
      }
    }
    return LiveClaudeProfileResolution(
      profiles: profiles,
      credentialTransitions: credentialTransitions
    )
  }

  private func resolvedClaudeCaptureProfile(
    for account: ProviderAccount,
    capturedRegistryID: String? = nil,
    persistedIdentity: ClaudeAccountIdentity? = nil
  ) async -> ClaudeCaptureProfileResolution? {
    let loader = claudeCredentialLoader
    guard var credentials = await Task.detached(operation: {
      loader(account.credentialSource)
    }).value else { return nil }
    let now = Date()
    let credentialResolution = await refreshedClaudeCredentialIfNeeded(
      account,
      credentials: credentials,
      now: now,
      capturedRegistryID: capturedRegistryID
    )
    credentials = credentialResolution.credentials
    let fingerprint = ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
    if let cached = claudeProfiles[account.id],
       cached.fingerprint == fingerprint {
      if let persistedIdentity, persistedIdentity.isStrong {
        return captureProfileResolution(
          profileApplyingPersistedIdentity(cached, identity: persistedIdentity),
          credential: credentialResolution
        )
      }
      if cached.hasStrongAccountIdentity {
        return captureProfileResolution(cached, credential: credentialResolution)
      }
    }
    // Stable profile identity outlives an access token. If refreshing an
    // expired saved row fails because the CLI already rotated the account,
    // its matching pinned profile still prevents a duplicate registry row.
    guard !credentials.isExpired(now: now) else {
      return captureProfileResolution(nil, credential: credentialResolution)
    }

    guard let verified = await freshlyVerifiedClaudeProfile(
      for: account,
      credentials: credentials,
      fingerprint: fingerprint
    )
    else {
      return captureProfileResolution(nil, credential: credentialResolution)
    }
    claudeProfiles[account.id] = verified
    profileFetchAttempts[account.id] = fingerprint
    emptyClaudeProfileFingerprints[account.id] = nil
    try? profileStore.save(claudeProfiles)
    enqueueClaudeQuotaNotificationScopeRestore()
    return captureProfileResolution(verified, credential: credentialResolution)
  }

  private func freshlyVerifiedClaudeProfile(
    for account: ProviderAccount,
    credentials: ClaudeCredentials,
    fingerprint: String
  ) async -> ClaudeProfile? {
    guard let fetched = try? await profileFetcher.fetchProfile(accessToken: credentials.accessToken),
          fetched.hasStableAccountIdentity
    else { return nil }
    let loader = claudeCredentialLoader
    guard let current = await Task.detached(operation: {
      loader(account.credentialSource)
    }).value,
      ProviderCredentialIdentity.fingerprint(of: current.accessToken) == fingerprint
    else { return nil }
    return fetched.verified(for: fingerprint)
  }

  private func captureProfileResolution(
    _ profile: ClaudeProfile?,
    credential: ClaudeCredentialResolution
  ) -> ClaudeCaptureProfileResolution {
    ClaudeCaptureProfileResolution(
      profile: profile,
      accessTokenFingerprint: ProviderCredentialIdentity.fingerprint(
        of: credential.credentials.accessToken
      ),
      credentialTransition: credential.transition,
      requiresReauthentication: credential.requiresReauthentication
    )
  }

  private func refreshedClaudeCredentialIfNeeded(
    _ account: ProviderAccount,
    credentials: ClaudeCredentials,
    now: Date,
    capturedRegistryID: String?
  ) async -> ClaudeCredentialResolution {
    guard credentials.isExpired(now: now),
          let refreshToken = credentials.refreshToken,
          !refreshToken.isEmpty
    else {
      return ClaudeCredentialResolution(
        credentials: credentials,
        transition: nil,
        requiresReauthentication: false
      )
    }
    let loader = claudeCredentialLoader
    let initialScopeID = account.credentialScopeID
    let result = await refreshClaudeCredential(
      account,
      now: now,
      capturedRegistryID: capturedRegistryID
    )
    guard let refreshed = await Task.detached(operation: {
      loader(account.credentialSource)
    }).value else {
      return ClaudeCredentialResolution(
        credentials: credentials,
        transition: nil,
        requiresReauthentication: false
      )
    }
    let refreshedAccount = ProviderAccount(
      provider: .claude,
      displayName: account.displayName,
      detail: account.detail,
      credentialSource: account.credentialSource,
      credentialIdentity: refreshed.accessToken
    )
    return ClaudeCredentialResolution(
      credentials: refreshed,
      transition: claudeCredentialTransition(
        from: result,
        initialScopeID: initialScopeID,
        refreshedScopeID: refreshedAccount.credentialScopeID
      ),
      requiresReauthentication: claudeCredentialRequiresReauthentication(
        result,
        attempted: credentials,
        current: refreshed,
        now: now
      )
    )
  }

  private func claudeCredentialTransition(
    from result: Result<ProviderFetchResult, Error>?,
    initialScopeID: String,
    refreshedScopeID: String
  ) -> ClaudeCredentialScopeTransition? {
    guard let evidence = result?.credentialTransitionEvidence,
          evidence.sourceScopeIDs.contains(initialScopeID),
          evidence.targetScopeID == refreshedScopeID
    else { return nil }
    return ClaudeCredentialScopeTransition(
      sourceScopeID: initialScopeID,
      targetScopeID: evidence.targetScopeID
    )
  }

  /// An invalid grant applies only to the exchanged refresh token; expiry
  /// cannot bind that verdict to a concurrently replaced credential pair.
  private func claudeCredentialRequiresReauthentication(
    _ result: Result<ProviderFetchResult, Error>?,
    attempted: ClaudeCredentials,
    current: ClaudeCredentials,
    now: Date
  ) -> Bool {
    guard result?.indicatesClaudeReauthenticationRequired == true,
          let attemptedGeneration = ProviderCredentialIdentity.claudeIdentity(
            refreshToken: attempted.refreshToken,
            accessToken: attempted.accessToken
          )
    else { return false }
    let currentGeneration = ProviderCredentialIdentity.claudeIdentity(
      refreshToken: current.refreshToken,
      accessToken: current.accessToken
    )
    return attemptedGeneration == currentGeneration && current.isExpired(now: now)
  }

  private func refreshClaudeCredential(
    _ account: ProviderAccount,
    now: Date,
    capturedRegistryID linkedCapturedRegistryID: String?
  ) async -> Result<ProviderFetchResult, Error>? {
    guard let descriptor = providers.first(where: { $0.id == .claude }) else { return nil }
    // The normal Claude fetch path owns refresh-token rotation, recovery
    // journals, and persistence for both saved and CLI-owned credentials.
    // Automatic capture has already closed the provider gate and drained older
    // activity, so this identity refresh cannot overlap another slot writer.
    let capturedRegistryID: String? =
      linkedCapturedRegistryID ?? account.credentialSource.quotariRegistryID
    return await descriptor.fetch(
      now: now,
      account: account,
      capturedRegistryID: capturedRegistryID
    )
  }

  private func unresolvedSavedClaudeProfileShouldBlock(_ account: ProviderAccount) async -> Bool {
    let loader = claudeCredentialLoader
    guard let credentials = await Task.detached(operation: {
      loader(account.credentialSource)
    }).value else {
      // A read failure is not evidence that the saved account is dead. Keep
      // duplicate prevention closed until a later scan can inspect it.
      return true
    }
    // A still-usable credential may only be facing a transient profile outage,
    // so keep the duplicate-safety gate. An expired row that the normal refresh
    // path could not recover must not permanently prevent a new live account
    // from entering management.
    return !credentials.isExpired(now: Date())
  }
}

private extension ProviderCredentialSource {
  var quotariRegistryID: String? {
    guard case let .quotariRegistry(id) = self else { return nil }
    return id
  }
}

private enum ResolvedSavedClaudeProfileOutcome {
  case resolved(ResolvedSavedClaudeProfile)
  case unresolved
  case ignored
}

struct ResolvedSavedClaudeProfile {
  let captured: CapturedAccount
  let profile: ClaudeProfile
  /// The OAuth endpoint definitively rejected this row's stored refresh token
  /// during this scan (invalid grant) and no newer pair rescued the slot — the
  /// snapshot can never renew itself again. Transient failures stay `false`.
  let requiresReauthentication: Bool
}

struct SavedClaudeProfileResolution {
  let profiles: [ResolvedSavedClaudeProfile]
  let hasUnresolvedProfile: Bool
}

struct ResolvedLiveClaudeProfile {
  let account: ProviderAccount
  let profile: ClaudeProfile
  let isRenewable: Bool
}

struct LiveClaudeProfileResolution {
  let profiles: [ResolvedLiveClaudeProfile]
  let credentialTransitions: [String: String]
}

private struct ClaudeCaptureProfileResolution {
  let profile: ClaudeProfile?
  let accessTokenFingerprint: String
  let credentialTransition: ClaudeCredentialScopeTransition?
  let requiresReauthentication: Bool
}

private struct ClaudeCredentialScopeTransition {
  let sourceScopeID: String
  let targetScopeID: String
}

private struct ClaudeCredentialResolution {
  let credentials: ClaudeCredentials
  let transition: ClaudeCredentialScopeTransition?
  let requiresReauthentication: Bool
}

private extension Result where Success == ProviderFetchResult, Failure == Error {
  /// Whether this fetch failed because the OAuth token endpoint rejected the
  /// stored refresh token outright. Unlike network or usage-request failures,
  /// an invalid grant is a permanent verdict on the stored pair.
  var indicatesClaudeReauthenticationRequired: Bool {
    guard case let .failure(error) = self else { return false }
    let underlying = (error as? ProviderFetchTransitionError)?.underlying ?? error
    guard let refreshError = underlying as? ClaudeTokenRefreshError else { return false }
    if case .reauthenticationRequired = refreshError {
      return true
    }
    return false
  }
}
