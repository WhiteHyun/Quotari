import Foundation
import os

/// Fetches Claude usage over OAuth using credentials discovered from the
/// environment, the Claude Code keychain item, or `~/.claude/.credentials.json`.
/// Not available when no credentials are found, so the pipeline falls through.
///
/// Expired access tokens are refreshed against the OAuth token endpoint and
/// the rotated pair is written back to the source, so Claude Code keeps
/// working with the same refresh token.
public struct ClaudeUsageStrategy: ProviderFetchStrategy {
  public let id = "claude.oauth"
  public let kind: ProviderFetchKind = .oauth

  private static let logger = Logger(subsystem: "com.quotari.QuotariCore", category: "claude-oauth")

  private let transport: any ProviderHTTPTransport
  private let usageURL: URL
  private let resolveCredentials: @Sendable () throws -> ResolvedClaudeCredentials
  private let refresher: (any ClaudeTokenRefreshing)?
  private let persister: any ClaudeCredentialPersisting
  private let capturedAccounts: CapturedAccountStore
  private let refreshCoordinator: ClaudeTokenRefreshCoordinator

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
    resolveCredentials: @escaping @Sendable () throws -> ResolvedClaudeCredentials = {
      try ClaudeCredentialsStore.loadResolved()
    },
    refresher: (any ClaudeTokenRefreshing)? = ClaudeTokenRefresher(),
    persister: (any ClaudeCredentialPersisting)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    refreshCoordinator: ClaudeTokenRefreshCoordinator = .shared
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.resolveCredentials = resolveCredentials
    self.refresher = refresher
    self.persister = persister ?? ClaudeCredentialsWriter(capturedAccounts: capturedAccounts)
    self.capturedAccounts = capturedAccounts
    self.refreshCoordinator = refreshCoordinator
  }

  public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
    if context.account != nil {
      return true
    }
    return (try? credentials(for: context)) != nil
  }

  public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    var resolved = try credentials(for: context)
    resolved = await refreshIfExpired(resolved, now: context.now)
    guard case .quotariRegistry = resolved.source else {
      return try await usageResult(with: resolved.credentials, context: context)
    }
    do {
      return try await usageResult(with: resolved.credentials, context: context)
    } catch ProviderHTTPError.unauthorized {
      // A saved account can be denied before its stored expiry says so (token
      // revoked early). The registry still holds a refresh token, so force
      // one refresh and retry once.
      let retried = await refreshIfExpired(
        resolved,
        now: context.now,
        deniedAccessToken: resolved.credentials.accessToken
      )
      guard retried.credentials.accessToken != resolved.credentials.accessToken else {
        throw ProviderHTTPError.unauthorized
      }
      return try await usageResult(with: retried.credentials, context: context)
    }
  }

  private func usageResult(
    with credentials: ClaudeCredentials,
    context: ProviderFetchContext
  ) async throws -> ProviderFetchResult {
    let data = try await transport.getJSON(
      url: usageURL,
      bearer: credentials.accessToken,
      headers: ["anthropic-beta": "oauth-2025-04-20"]
    )
    var usage = try ClaudeUsageParser.parse(data, provider: context.provider, now: context.now)
    if usage.plan == nil {
      usage.plan = PlanLabel.claude(
        subscriptionType: credentials.subscriptionType,
        rateLimitTier: credentials.rateLimitTier
      )
    }
    return ProviderFetchResult(usage: usage, sourceLabel: "Claude")
  }

  public func shouldFallback(on error: Error) -> Bool {
    if let fetchError = error as? ProviderFetchError,
       case .selectedCredentialUnavailable = fetchError {
      return false
    }
    return !(error is ProviderHTTPError)
  }

  private func credentials(for context: ProviderFetchContext) throws -> ResolvedClaudeCredentials {
    if let account = context.account {
      do {
        return try ResolvedClaudeCredentials(
          credentials: ClaudeCredentialsStore.load(
            source: account.credentialSource,
            capturedAccounts: capturedAccounts
          ),
          source: account.credentialSource
        )
      } catch {
        throw ProviderFetchError.selectedCredentialUnavailable(context.provider)
      }
    }
    return try resolveCredentials()
  }
}

// MARK: - Saved-account token refresh

private extension ClaudeUsageStrategy {
  /// Refreshing only once the token is actually (about to be) expired keeps
  /// the window for racing Claude Code's own refresh as small as possible.
  /// The whole refresh-persist-fallback transaction runs under the
  /// coordinator, keyed by source *and* refresh-token generation, so
  /// concurrent Quotari fetches can't burn the rotating token twice and a
  /// caller holding a newer pair never joins an older generation's run.
  private func refreshIfExpired(
    _ resolved: ResolvedClaudeCredentials,
    now: Date,
    deniedAccessToken: String? = nil
  ) async -> ResolvedClaudeCredentials {
    let credentials = resolved.credentials
    guard deniedAccessToken != nil || credentials.isExpired(now: now),
          let refreshToken = credentials.refreshToken,
          let refresher
    else { return resolved }
    let key = "\(resolved.source.stableID)#\(refreshToken)"
    return await refreshCoordinator.resolve(key: key) {
      // Double-check inside the transaction: a previous transaction (or
      // Claude Code itself) may have persisted a fresh pair while we waited.
      // A pair the endpoint just denied doesn't count, whatever its stored
      // expiry claims.
      if let reloaded = reloadedFromSource(resolved, now: now),
         reloaded.credentials.accessToken != deniedAccessToken {
        return reloaded
      }
      var base = resolved
      // A rotated pair whose registry write-back failed: retry the write
      // before submitting the burned refresh token again.
      if let pending = await takePending(source: resolved.source) {
        if let retried = await persisted(pending, resolved: base, now: now) {
          return retried
        }
        switch await resolvedStaleWrite(pending, enteredWith: refreshToken, fallback: base, now: now) {
        case let .resolved(outcome):
          return outcome
        case let .exchange(current):
          base = current
        }
      }
      return await exchanged(base, refreshToken: refreshToken, refresher: refresher, now: now)
    }
  }

  /// One fresh exchange of `refreshToken`, persisted over `base`. On a stale
  /// write the shared resolution decides; a failed exchange falls back to the
  /// stored pair and lets the API answer 401 as before.
  private func exchanged(
    _ base: ResolvedClaudeCredentials,
    refreshToken: String,
    refresher: any ClaudeTokenRefreshing,
    now: Date
  ) async -> ResolvedClaudeCredentials {
    do {
      let grant = try await refresher.refresh(
        refreshToken: refreshToken,
        scopes: base.credentials.scopes,
        now: now
      )
      let pending = ClaudePendingGrant(
        grant: grant,
        previousAccessToken: base.credentials.accessToken,
        consumedRefreshToken: refreshToken
      )
      if let updated = await persisted(pending, resolved: base, now: now) {
        return updated
      }
      switch await resolvedStaleWrite(pending, enteredWith: refreshToken, fallback: base, now: now) {
      case let .resolved(outcome):
        return outcome
      case let .exchange(current):
        // Same still-valid (non-rotating) token: their write stays stored
        // and can refresh itself later; the grant still serves this fetch.
        return current.credentials.isExpired(now: now) ? inMemory(current, grant) : current
      }
    } catch {
      // Claude Code may have rotated the token first; its fresher pair
      // will already be at the source, so re-read once before giving up.
      // If that doesn't help either, let the API answer 401 as before.
      Self.logger.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")
      return reloadedFromSource(base, now: now) ?? base
    }
  }

  private enum StaleWriteResolution {
    case resolved(ResolvedClaudeCredentials)
    /// The stored pair is the entered generation and provably still
    /// exchangeable — either it was never consumed, or its exchange showed
    /// the endpoint keeps the token alive.
    case exchange(ResolvedClaudeCredentials)
  }

  /// The source was rewritten while a refreshed pair was in hand (its
  /// guarded write was rejected as stale). For CLI-owned sources whoever
  /// rewrote them is the truth — Claude Code recovers its own rotations. A
  /// registry pair has no co-owner, so the Codex rules apply: a pair riding
  /// a token the exchange rotated away can never refresh again (superseded
  /// by the grant); a different generation restarts re-keyed.
  private func resolvedStaleWrite(
    _ pending: ClaudePendingGrant,
    enteredWith refreshToken: String,
    fallback: ResolvedClaudeCredentials,
    now: Date
  ) async -> StaleWriteResolution {
    guard case .quotariRegistry = fallback.source else {
      // Someone re-logged-in (or otherwise replaced the pair) since we read
      // it; their credentials are the truth now, not our refreshed grant.
      Self.logger.notice("Credential source changed during refresh; using its pair instead.")
      return .resolved(reloadedFromSource(fallback, now: now) ?? fallback)
    }
    guard let current = try? ClaudeCredentialsStore.load(
      source: fallback.source,
      capturedAccounts: capturedAccounts
    ) else {
      // The reread failed outright (not just moved on): the grant may hold
      // the only refresh token that still works, so keep it queued for the
      // next transaction and fetch with it in the meantime.
      await rememberPending(pending, source: fallback.source)
      return .resolved(inMemory(fallback, pending.grant))
    }
    let stored = ResolvedClaudeCredentials(credentials: current, source: fallback.source)
    if current.refreshToken == pending.consumedRefreshToken, pending.rotatedRefreshToken {
      return await .resolved(supersede(pending, stored: stored, now: now))
    }
    // The grant is obsolete on the remaining paths — clear any durable copy
    // so it isn't retried (against a pair that has moved on) every launch.
    if case let .quotariRegistry(id) = fallback.source {
      try? capturedAccounts.removePendingGrant(id: id)
    }
    if current.refreshToken != refreshToken {
      return await .resolved(refreshIfExpired(stored, now: now))
    }
    return .exchange(stored)
  }

  /// The stored registry pair rides a refresh token an exchange rotated away
  /// — it can never refresh again, so the pending grant supersedes it no
  /// matter who wrote it.
  private func supersede(
    _ pending: ClaudePendingGrant,
    stored: ResolvedClaudeCredentials,
    now: Date
  ) async -> ResolvedClaudeCredentials {
    let reapplied = ClaudePendingGrant(
      grant: pending.grant,
      previousAccessToken: stored.credentials.accessToken,
      consumedRefreshToken: pending.consumedRefreshToken
    )
    if let applied = await persisted(reapplied, resolved: stored, now: now) {
      return applied
    }
    // Yet another concurrent write landed; at some point theirs is the truth.
    return reloadedFromSource(stored, now: now) ?? inMemory(stored, pending.grant)
  }

  /// Persists the pending grant and returns the credentials to fetch with,
  /// or nil when the source holds a different pair than the grant replaces.
  /// A registry write failure keeps the grant queued for retry and still
  /// returns it: the rotation already happened server-side, so the in-memory
  /// pair is the freshest one there is.
  private func persisted(
    _ pending: ClaudePendingGrant,
    resolved: ResolvedClaudeCredentials,
    now: Date
  ) async -> ResolvedClaudeCredentials? {
    do {
      try persister.persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        to: resolved.source
      )
      // The source holds the grant now; any durable copy is obsolete.
      if case let .quotariRegistry(id) = resolved.source {
        try? capturedAccounts.removePendingGrant(id: id)
      }
    } catch ClaudeCredentialPersistError.staleSource {
      return nil
    } catch {
      // The refresh already happened server-side, so dropping the fetch
      // wouldn't undo the rotation — continue with the in-memory pair, and
      // for a registry source (no co-owner to heal it) queue the write.
      Self.logger.error("Persisting refreshed tokens failed: \(error.localizedDescription, privacy: .public)")
      if case .quotariRegistry = resolved.source {
        await rememberPending(pending, source: resolved.source)
      }
    }
    return inMemory(resolved, pending.grant)
  }

  /// Memory first (cheap), then the durable copy a previous launch left.
  /// The durable copy is deliberately NOT consumed here: it holds the only
  /// rotated pair, so it stays until the registry write succeeds (persisted
  /// clears it) or the grant is proven obsolete (the stale-write resolution
  /// clears it) — a crash mid-retry must not lose it.
  private func takePending(source: ProviderCredentialSource) async -> ClaudePendingGrant? {
    if let pending = await refreshCoordinator.takeUnpersisted(sourceID: source.stableID) {
      return pending
    }
    guard case let .quotariRegistry(id) = source,
          let data = capturedAccounts.pendingGrantData(id: id),
          let pending = try? JSONDecoder().decode(ClaudePendingGrant.self, from: data)
    else { return nil }
    return pending
  }

  /// Queues in memory and, best-effort, durably — so quitting before the
  /// next fetch doesn't lose the only rotated pair.
  private func rememberPending(_ pending: ClaudePendingGrant, source: ProviderCredentialSource) async {
    await refreshCoordinator.rememberUnpersisted(pending, sourceID: source.stableID)
    if case let .quotariRegistry(id) = source, let data = try? JSONEncoder().encode(pending) {
      try? capturedAccounts.savePendingGrant(data, id: id)
    }
  }

  /// The credentials patched with a grant that isn't (or isn't yet) stored —
  /// good for fetching with while the source catches up.
  private func inMemory(
    _ resolved: ResolvedClaudeCredentials,
    _ grant: ClaudeTokenGrant
  ) -> ResolvedClaudeCredentials {
    var credentials = resolved.credentials
    credentials.accessToken = grant.accessToken
    credentials.refreshToken = grant.refreshToken ?? credentials.refreshToken
    credentials.expiresAt = grant.expiresAt
    credentials.scopes = grant.scopes ?? credentials.scopes
    return ResolvedClaudeCredentials(credentials: credentials, source: resolved.source)
  }

  private func reloadedFromSource(
    _ resolved: ResolvedClaudeCredentials,
    now: Date
  ) -> ResolvedClaudeCredentials? {
    guard let reloaded = try? ClaudeCredentialsStore.load(
      source: resolved.source,
      capturedAccounts: capturedAccounts
    ), !reloaded.isExpired(now: now)
    else { return nil }
    return ResolvedClaudeCredentials(credentials: reloaded, source: resolved.source)
  }
}
