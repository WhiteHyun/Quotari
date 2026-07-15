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
    var profiles: [(CapturedAccount, ClaudeProfile)] = []
    var hasUnresolvedProfile = false
    for captured in accounts {
      if let resolution = await resolvedClaudeCaptureProfile(for: captured.providerAccount),
         let profile = resolution.profile {
        profiles.append((captured, profile))
      } else if await unresolvedSavedClaudeProfileShouldBlock(captured.providerAccount) {
        hasUnresolvedProfile = true
      }
    }
    return SavedClaudeProfileResolution(
      profiles: profiles,
      hasUnresolvedProfile: hasUnresolvedProfile
    )
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
    capturedRegistryID: String? = nil
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
    let credentialTransition = credentialResolution.transition
    let fingerprint = ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
    if let cached = claudeProfiles[account.id],
       cached.fingerprint == fingerprint,
       !cached.isEmpty {
      return ClaudeCaptureProfileResolution(
        profile: cached,
        credentialTransition: credentialTransition
      )
    }
    // Stable profile identity outlives an access token. If refreshing an
    // expired saved row fails because the CLI already rotated the account,
    // its matching pinned profile still prevents a duplicate registry row.
    guard !credentials.isExpired(now: now) else {
      return ClaudeCaptureProfileResolution(
        profile: nil,
        credentialTransition: credentialTransition
      )
    }

    guard let fetched = try? await profileFetcher.fetchProfile(accessToken: credentials.accessToken),
          !fetched.isEmpty,
          let current = await Task.detached(operation: {
            loader(account.credentialSource)
          }).value,
          ProviderCredentialIdentity.fingerprint(of: current.accessToken) == fingerprint
    else {
      return ClaudeCaptureProfileResolution(
        profile: nil,
        credentialTransition: credentialTransition
      )
    }
    let verified = fetched.verified(for: fingerprint)
    claudeProfiles[account.id] = verified
    profileFetchAttempts[account.id] = fingerprint
    emptyClaudeProfileFingerprints[account.id] = nil
    try? profileStore.save(claudeProfiles)
    enqueueClaudeQuotaNotificationScopeRestore()
    return ClaudeCaptureProfileResolution(
      profile: verified,
      credentialTransition: credentialTransition
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
    else { return ClaudeCredentialResolution(credentials: credentials, transition: nil) }
    let loader = claudeCredentialLoader
    let initialScopeID = account.credentialScopeID
    let result = await refreshClaudeCredential(
      account,
      now: now,
      capturedRegistryID: capturedRegistryID
    )
    guard let refreshed = await Task.detached(operation: {
      loader(account.credentialSource)
    }).value else { return ClaudeCredentialResolution(credentials: credentials, transition: nil) }
    let refreshedAccount = ProviderAccount(
      provider: .claude,
      displayName: account.displayName,
      detail: account.detail,
      credentialSource: account.credentialSource,
      credentialIdentity: refreshed.accessToken
    )
    let transition: ClaudeCredentialScopeTransition? = if let evidence = result?.credentialTransitionEvidence,
                                                          evidence.sourceScopeIDs.contains(initialScopeID),
                                                          evidence.targetScopeID == refreshedAccount.credentialScopeID {
      ClaudeCredentialScopeTransition(
        sourceScopeID: initialScopeID,
        targetScopeID: evidence.targetScopeID
      )
    } else {
      nil
    }
    return ClaudeCredentialResolution(credentials: refreshed, transition: transition)
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

struct SavedClaudeProfileResolution {
  let profiles: [(CapturedAccount, ClaudeProfile)]
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
  let credentialTransition: ClaudeCredentialScopeTransition?
}

private struct ClaudeCredentialScopeTransition {
  let sourceScopeID: String
  let targetScopeID: String
}

private struct ClaudeCredentialResolution {
  let credentials: ClaudeCredentials
  let transition: ClaudeCredentialScopeTransition?
}
