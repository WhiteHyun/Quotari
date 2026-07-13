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

  /// Resolves email labels for Claude accounts. The retry key is a fingerprint
  /// of the *access token* (not the durable identity), so any token rotation —
  /// including an access-token-only refresh — triggers exactly one fresh
  /// fetch, and a stuck credential is retried the moment its token changes.
  /// A cached profile whose fingerprint no longer matches the live credential
  /// is dropped once a confirming fetch proves the credential bad, so a reused
  /// credential slot never keeps showing the previous account's email.
  func refreshClaudeProfiles() {
    for account in accounts[.claude] ?? [] where !profileFetchTasks.contains(account.id) {
      let id = account.id
      let source = account.credentialSource
      profileFetchTasks.insert(id)
      Task {
        defer { profileFetchTasks.remove(id) }
        await resolveClaudeProfile(id: id, source: source)
      }
    }
  }

  /// One account's profile-resolution loop, run under a per-account in-flight
  /// guard. It re-reads the credential after each fetch: because the guard
  /// blocks a concurrent generation from starting, the credential can rotate
  /// *during* a fetch — so once a fetch finishes we check whether the live
  /// token changed and fetch again if so, instead of leaving a stale write
  /// with nothing queued. Bounded so a pathological rotation can't spin.
  private func resolveClaudeProfile(id: String, source: ProviderCredentialSource) async {
    let fetcher = profileFetcher
    let loader = claudeCredentialLoader
    for _ in 0 ..< 5 {
      guard let credential = await Task.detached(operation: { () -> Credential? in
        guard let credentials = loader(source) else { return nil }
        return Credential(
          fingerprint: ProviderCredentialIdentity.fingerprint(of: credentials.accessToken),
          token: credentials.accessToken
        )
      }).value else { return }
      // The current token was already attempted (success or auth failure) —
      // nothing more to do until it changes.
      guard profileFetchAttempts[id] != credential.fingerprint else { return }
      // Claude's payload has no durable pre-fetch account id (both tokens
      // rotate), so we can't tell "different account" from "same account, new
      // token" before fetching. The cached email therefore stays visible until
      // a fetch confirms otherwise: an access-token rotation is usually the
      // same account (no flicker), and a genuinely different account is dropped
      // once its fetch returns empty or 401. (A reused slot seen only while
      // offline keeps the prior email until connectivity returns — an accepted
      // tradeoff, since flickering on every routine token rotation is worse.)
      let cachedIsForOldToken = claudeProfiles[id].map { $0.fingerprint != credential.fingerprint } ?? false
      profileFetchAttempts[id] = credential.fingerprint
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
        // The token is denied. If it's a token we hadn't fetched with before,
        // the cached email may belong to a now-replaced account, so drop it.
        dropStaleProfile(id: id, cachedIsForOldToken: cachedIsForOldToken)
        // Don't break: a usage refresh may have rotated and persisted a new
        // token during this 401, so loop to re-read the source. If the token
        // is unchanged, the already-attempted guard above returns next pass.
      } catch {
        // Transient (network / 5xx): keep any cache, clear the marker so the
        // next cycle retries with the same token, and stop looping.
        if profileFetchAttempts[id] == credential.fingerprint {
          profileFetchAttempts[id] = nil
        }
        return
      }
    }
  }

  private func dropStaleProfile(id: String, cachedIsForOldToken: Bool) {
    guard cachedIsForOldToken, claudeProfiles[id] != nil else { return }
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
}
