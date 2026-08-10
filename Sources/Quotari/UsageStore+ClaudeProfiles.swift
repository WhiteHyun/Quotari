import Foundation
import QuotariCore

// MARK: - Claude account email labels

extension UsageStore {
  /// The label to show for an account: a fetched Claude email when available,
  /// otherwise the discovered display name.
  func accountLabel(for account: ProviderAccount) -> String {
    if account.provider == .claude, let email = claudeProfiles[account.id]?.email, !email.isEmpty {
      return email
    }
    return account.displayName
  }

  func organizationName(for account: ProviderAccount) -> String? {
    claudeProfiles[account.id]?.organizationName
  }

  /// Older releases cached a live Claude profile before creating its managed
  /// registry row. Discovery proves the live and saved payloads are the same
  /// renewable identity; re-read both before copying so a reused slot cannot
  /// donate its profile to the previous account. The saved copy gets its own
  /// access-token fingerprint because the two stores may be on different
  /// access generations while sharing the same refresh identity.
  func migrateCachedClaudeProfilesToCapturedAccounts() async {
    let loader = claudeCredentialLoader
    var changed = false
    for (liveID, saved) in capturedEquivalents where saved.provider == .claude {
      guard let live = accounts[.claude]?.first(where: { $0.id == liveID }),
            let cached = claudeProfiles[liveID],
            !cached.isEmpty
      else { continue }
      let evidence = await Task.detached {
        CachedClaudeProfileMigrationEvidence(
          live: loader(live.credentialSource),
          saved: loader(saved.credentialSource)
        )
      }.value
      guard cached.fingerprint == evidence.liveFingerprint,
            evidence.liveIdentity != nil,
            evidence.liveIdentity == evidence.savedIdentity,
            let savedFingerprint = evidence.savedFingerprint
      else { continue }
      let migrated = cached.verified(for: savedFingerprint)
      guard claudeProfiles[saved.id] != migrated else { continue }
      claudeProfiles[saved.id] = migrated
      profileFetchAttempts[saved.id] = savedFingerprint
      emptyClaudeProfileFingerprints[saved.id] = nil
      changed = true
    }
    guard changed else { return }
    try? profileStore.save(claudeProfiles)
    enqueueClaudeQuotaNotificationScopeRestore()
  }

  /// Resolves email labels for Claude accounts. The retry key is a fingerprint
  /// of the *access token* (not the durable identity), so any token rotation —
  /// including an access-token-only refresh — triggers exactly one fresh
  /// fetch, and a stuck credential is retried the moment its token changes.
  /// A cached profile whose fingerprint no longer matches the live credential
  /// is dropped once a confirming fetch proves the credential bad, so a reused
  /// credential slot never keeps showing the previous account's email.
  func refreshClaudeProfiles() {
    guard isProviderEnabled(.claude) else { return }
    let revision = accountRevisions[.claude] ?? 0
    for account in accounts[.claude] ?? [] where !profileFetchTasks.contains(account.id) {
      let id = account.id
      let source = account.credentialSource
      profileFetchTasks.insert(id)
      Task {
        defer {
          profileFetchTasks.remove(id)
          // A rapid disable/re-enable can happen while the old fetch is
          // suspended. The enabling refresh sees the in-flight guard, so the
          // superseded task queues the current generation after releasing it.
          if isProviderEnabled(.claude),
             (accountRevisions[.claude] ?? 0) != revision {
            refreshClaudeProfiles()
          }
        }
        await resolveClaudeProfile(id: id, source: source, revision: revision)
      }
    }
  }

  /// One account's profile-resolution loop, run under a per-account in-flight
  /// guard. It re-reads the credential after each fetch: because the guard
  /// blocks a concurrent generation from starting, the credential can rotate
  /// *during* a fetch — so once a fetch finishes we check whether the live
  /// token changed and fetch again if so, instead of leaving a stale write
  /// with nothing queued. Bounded so a pathological rotation can't spin.
  private func resolveClaudeProfile(
    id: String,
    source: ProviderCredentialSource,
    revision: UInt
  ) async {
    let fetcher = profileFetcher
    for _ in 0 ..< 5 {
      guard let attempt = await nextClaudeProfileAttempt(
        id: id,
        source: source,
        revision: revision
      ) else { return }
      do {
        let profile = try await fetcher.fetchProfile(accessToken: attempt.credential.token)
        guard canFinishClaudeProfileAttempt(id: id, attempt: attempt, revision: revision) else { return }
        let shouldRetry = await storeFetchedClaudeProfile(
          profile,
          id: id,
          source: source,
          attempt: attempt,
          revision: revision
        )
        if !shouldRetry {
          return
        }
      } catch ProviderHTTPError.unauthorized {
        guard canFinishClaudeProfileAttempt(id: id, attempt: attempt, revision: revision) else { return }
        // The token is denied. If it's a token we hadn't fetched with before,
        // the cached email may belong to a now-replaced account, so drop it.
        dropStaleProfile(id: id, cachedIsForOldToken: attempt.cachedIsForOldToken)
        // Don't break: a usage refresh may have rotated and persisted a new
        // token during this 401, so loop to re-read the source. If the token
        // is unchanged, the already-attempted guard above returns next pass.
      } catch {
        guard canFinishClaudeProfileAttempt(id: id, attempt: attempt, revision: revision) else { return }
        // Transient (network / 5xx): keep any cache, clear the marker so the
        // next cycle retries with the same token, and stop looping.
        clearProfileFetchAttempt(id: id, fingerprint: attempt.credential.fingerprint)
        return
      }
    }
  }

  private func nextClaudeProfileAttempt(
    id: String,
    source: ProviderCredentialSource,
    revision: UInt
  ) async -> ProfileAttempt? {
    guard isCurrentClaudeProfileGeneration(revision) else { return nil }
    let loader = claudeCredentialLoader
    guard let credential = await Task.detached(operation: { () -> Credential? in
      guard let credentials = loader(source) else { return nil }
      return Credential(
        fingerprint: ProviderCredentialIdentity.fingerprint(of: credentials.accessToken),
        token: credentials.accessToken
      )
    }).value else { return nil }
    guard isCurrentClaudeProfileGeneration(revision),
          profileFetchAttempts[id] != credential.fingerprint
    else { return nil }
    // Keep the prior email through routine token rotation or a transient
    // outage. A successful empty response or 401 confirms when it is stale.
    let cachedIsForOldToken = claudeProfiles[id].map {
      $0.fingerprint != credential.fingerprint
    } ?? false
    profileFetchAttempts[id] = credential.fingerprint
    return ProfileAttempt(credential: credential, cachedIsForOldToken: cachedIsForOldToken)
  }

  /// Returns true when the credential rotated in flight and needs another pass.
  private func storeFetchedClaudeProfile(
    _ profile: ClaudeProfile,
    id: String,
    source: ProviderCredentialSource,
    attempt: ProfileAttempt,
    revision: UInt
  ) async -> Bool {
    let loader = claudeCredentialLoader
    let liveFingerprint = await Task.detached(operation: { () -> String? in
      loader(source).map { ProviderCredentialIdentity.fingerprint(of: $0.accessToken) }
    }).value
    guard canFinishClaudeProfileAttempt(id: id, attempt: attempt, revision: revision) else { return false }
    guard liveFingerprint == attempt.credential.fingerprint else { return true }
    if profile.isEmpty {
      // A verified profile for this exact credential may have arrived through
      // another accepted path while this request was suspended. A late empty
      // response is not newer identity evidence and must not clear or replay
      // notification scope over it.
      if claudeProfiles[id]?.fingerprint == attempt.credential.fingerprint {
        return false
      }
      dropStaleProfile(id: id, cachedIsForOldToken: attempt.cachedIsForOldToken)
      emptyClaudeProfileFingerprints[id] = attempt.credential.fingerprint
    } else {
      let verified = ClaudeProfile(
        accountID: profile.accountID,
        email: profile.email,
        organizationID: profile.organizationID,
        organizationName: profile.organizationName,
        fingerprint: attempt.credential.fingerprint
      )
      // A live row hides its captured copy, so the saved row is not otherwise
      // visited by this profile pass. Persist the same verified identity under
      // the registry id; a later external token rotation can then prove that
      // the newly fingerprinted live credential is still this saved account.
      var savedProfileCopy: (id: String, fingerprint: String)?
      if let saved = capturedEquivalents[id] {
        let savedFingerprint = await savedFingerprintForClaudeProfileCopy(
          verified,
          from: source,
          to: saved
        )
        let currentLiveFingerprint = await Task.detached(operation: { () -> String? in
          loader(source).map { ProviderCredentialIdentity.fingerprint(of: $0.accessToken) }
        }).value
        guard canFinishClaudeProfileAttempt(id: id, attempt: attempt, revision: revision) else { return false }
        guard currentLiveFingerprint == attempt.credential.fingerprint else { return true }
        if let savedFingerprint {
          savedProfileCopy = (saved.id, savedFingerprint)
        }
      }
      emptyClaudeProfileFingerprints[id] = nil
      claudeProfiles[id] = verified
      if let savedProfileCopy {
        claudeProfiles[savedProfileCopy.id] = verified.verified(for: savedProfileCopy.fingerprint)
        profileFetchAttempts[savedProfileCopy.id] = savedProfileCopy.fingerprint
        emptyClaudeProfileFingerprints[savedProfileCopy.id] = nil
      }
      try? profileStore.save(claudeProfiles)
    }
    enqueueClaudeQuotaNotificationScopeRestore()
    return false
  }

  private func savedFingerprintForClaudeProfileCopy(
    _ profile: ClaudeProfile,
    from liveSource: ProviderCredentialSource,
    to saved: ProviderAccount
  ) async -> String? {
    let loader = claudeCredentialLoader
    let evidence = await Task.detached { () -> ClaudeProfileCopyEvidence in
      let live = loader(liveSource)
      let stored = loader(saved.credentialSource)
      return ClaudeProfileCopyEvidence(
        liveIdentity: live.flatMap {
          ProviderCredentialIdentity.claudeIdentity(
            refreshToken: $0.refreshToken,
            accessToken: $0.accessToken
          )
        },
        savedIdentity: stored.flatMap {
          ProviderCredentialIdentity.claudeIdentity(
            refreshToken: $0.refreshToken,
            accessToken: $0.accessToken
          )
        },
        savedAccessTokenFingerprint: stored.map {
          ProviderCredentialIdentity.fingerprint(of: $0.accessToken)
        }
      )
    }.value
    if evidence.liveIdentity == evidence.savedIdentity,
       evidence.liveIdentity != nil,
       let savedFingerprint = evidence.savedAccessTokenFingerprint {
      return savedFingerprint
    }
    guard let savedProfile = claudeProfiles[saved.id],
          let savedFingerprint = evidence.savedAccessTokenFingerprint,
          savedProfile.fingerprint == savedFingerprint,
          profile.stronglyIdentifiesSameAccount(as: savedProfile)
    else { return nil }
    return savedFingerprint
  }

  private struct ClaudeProfileCopyEvidence: Sendable {
    let liveIdentity: String?
    let savedIdentity: String?
    let savedAccessTokenFingerprint: String?
  }

  private struct CachedClaudeProfileMigrationEvidence: Sendable {
    let liveIdentity: String?
    let savedIdentity: String?
    let liveFingerprint: String?
    let savedFingerprint: String?

    init(live: ClaudeCredentials?, saved: ClaudeCredentials?) {
      liveIdentity = live.flatMap {
        ProviderCredentialIdentity.claudeIdentity(
          refreshToken: $0.refreshToken,
          accessToken: $0.accessToken
        )
      }
      savedIdentity = saved.flatMap {
        ProviderCredentialIdentity.claudeIdentity(
          refreshToken: $0.refreshToken,
          accessToken: $0.accessToken
        )
      }
      liveFingerprint = live.map { ProviderCredentialIdentity.fingerprint(of: $0.accessToken) }
      savedFingerprint = saved.map { ProviderCredentialIdentity.fingerprint(of: $0.accessToken) }
    }
  }

  private func canFinishClaudeProfileAttempt(
    id: String,
    attempt: ProfileAttempt,
    revision: UInt
  ) -> Bool {
    guard isCurrentClaudeProfileGeneration(revision) else {
      clearProfileFetchAttempt(id: id, fingerprint: attempt.credential.fingerprint)
      return false
    }
    return true
  }

  private func dropStaleProfile(id: String, cachedIsForOldToken: Bool) {
    guard isProviderEnabled(.claude),
          cachedIsForOldToken,
          claudeProfiles[id] != nil
    else { return }
    claudeProfiles[id] = nil
    try? profileStore.save(claudeProfiles)
  }

  private func isCurrentClaudeProfileGeneration(_ revision: UInt) -> Bool {
    !Task.isCancelled
      && isProviderEnabled(.claude)
      && (accountRevisions[.claude] ?? 0) == revision
  }

  private func clearProfileFetchAttempt(id: String, fingerprint: String) {
    guard profileFetchAttempts[id] == fingerprint else { return }
    profileFetchAttempts[id] = nil
  }

  private struct Credential: Sendable {
    var fingerprint: String
    var token: String
  }

  private struct ProfileAttempt: Sendable {
    var credential: Credential
    var cachedIsForOldToken: Bool
  }
}
