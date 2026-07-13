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

  static let logger = Logger(subsystem: "com.quotari.QuotariCore", category: "claude-oauth")

  private let transport: any ProviderHTTPTransport
  private let usageURL: URL
  private let resolveCredentials: @Sendable () throws -> ResolvedClaudeCredentials
  private let refresher: (any ClaudeTokenRefreshing)?
  private let persister: any ClaudeCredentialPersisting
  let capturedAccounts: CapturedAccountStore
  let refreshCoordinator: ClaudeTokenRefreshCoordinator

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
    resolveCredentials: @escaping @Sendable () throws -> ResolvedClaudeCredentials = {
      try ClaudeCredentialsStore.loadResolved()
    },
    refresher: (any ClaudeTokenRefreshing)? = ClaudeTokenRefresher(),
    persister: (any ClaudeCredentialPersisting)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    mirroredCredentialsFileURL: URL? = nil,
    refreshCoordinator: ClaudeTokenRefreshCoordinator = .shared
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.resolveCredentials = resolveCredentials
    self.refresher = refresher
    self.persister = persister ?? ClaudeCredentialsWriter(
      capturedAccounts: capturedAccounts,
      mirroredCredentialsFileURL: mirroredCredentialsFileURL
    )
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
    if let capturedRegistryID = context.capturedRegistryID {
      try recoverLinkedRegistryGrant(id: capturedRegistryID)
    }
    var resolved = try credentials(for: context)
    resolved = await refreshIfExpired(
      resolved,
      now: context.now,
      capturedRegistryID: context.capturedRegistryID
    )
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
        deniedAccessToken: resolved.credentials.accessToken,
        capturedRegistryID: context.capturedRegistryID
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

// MARK: - Token refresh

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
    deniedAccessToken: String? = nil,
    capturedRegistryID: String? = nil
  ) async -> ResolvedClaudeCredentials {
    let credentials = resolved.credentials
    if let capturedRegistryID,
       await cachedMirrorBlocksRefresh(resolved, registryID: capturedRegistryID) {
      return resolved
    }
    let refreshNeeded = deniedAccessToken != nil || credentials.isExpired(now: now)
    let durablePending: ClaudePendingGrant?
    do {
      durablePending = try loadDurablePending(source: resolved.source)
    } catch {
      // A read failure is not proof of absence. Exchanging the stored token
      // could consume it while the only already-issued replacement remains
      // temporarily unreadable, so fail closed and let the API report the
      // old credential as unusable.
      Self.logger.error("Reading a pending Claude grant failed: \(error.localizedDescription, privacy: .public)")
      return resolved
    }
    guard refreshNeeded || durablePending != nil else { return resolved }
    let generation = credentials.refreshToken
      ?? durablePending?.consumedRefreshToken
      ?? credentials.accessToken
    let key = "\(resolved.source.stableID)#\(generation)"
    let resolution = await refreshCoordinator.resolve(key: key) {
      await resolveRefreshTransaction(
        resolved,
        durablePending: durablePending,
        deniedAccessToken: deniedAccessToken,
        now: now
      )
    }
    if let capturedRegistryID, let acceptedGrant = resolution.acceptedGrant {
      _ = mirrorAcceptedGrant(acceptedGrant, to: capturedRegistryID)
    }
    return resolution.resolved
  }

  private func resolveRefreshTransaction(
    _ resolved: ResolvedClaudeCredentials,
    durablePending: ClaudePendingGrant?,
    deniedAccessToken: String?,
    now: Date
  ) async -> ClaudeRefreshResolution {
    var base = resolved
    // Retry a rotated pair before submitting its burned token again.
    if let pending = await takePending(source: resolved.source, durablePending: durablePending) {
      if let retried = await persisted(pending, resolved: base) {
        return retried
      }
      switch await resolvedStaleWrite(
        pending,
        enteredWith: pending.consumedRefreshToken,
        fallback: base,
        now: now
      ) {
      case let .resolved(outcome):
        return outcome
      case let .exchange(current):
        base = current
      }
    }
    // Durable recovery runs before this reload so an installed or externally
    // superseded grant is cleaned up even while the current pair is fresh.
    if let reloaded = reloadedFromSource(base, now: now),
       reloaded.credentials.accessToken != deniedAccessToken {
      return ClaudeRefreshResolution(resolved: reloaded)
    }
    guard deniedAccessToken != nil || base.credentials.isExpired(now: now),
          let refreshToken = base.credentials.refreshToken,
          let refresher
    else { return ClaudeRefreshResolution(resolved: base) }
    return await exchanged(
      base,
      refreshToken: refreshToken,
      refresher: refresher,
      now: now
    )
  }

  /// One fresh exchange of `refreshToken`, persisted over `base`. On a stale
  /// write the shared resolution decides; a failed exchange falls back to the
  /// stored pair and lets the API answer 401 as before.
  private func exchanged(
    _ base: ResolvedClaudeCredentials,
    refreshToken: String,
    refresher: any ClaudeTokenRefreshing,
    now: Date
  ) async -> ClaudeRefreshResolution {
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
      if let updated = await persisted(
        pending,
        resolved: base
      ) {
        return updated
      }
      switch await resolvedStaleWrite(pending, enteredWith: refreshToken, fallback: base, now: now) {
      case let .resolved(outcome):
        return outcome
      case let .exchange(current):
        // Same still-valid (non-rotating) token: their write stays stored
        // and can refresh itself later; the grant still serves this fetch.
        return ClaudeRefreshResolution(
          resolved: current.credentials.isExpired(now: now) ? inMemory(current, grant) : current
        )
      }
    } catch {
      // Claude Code may have rotated the token first; its fresher pair
      // will already be at the source, so re-read once before giving up.
      // If that doesn't help either, let the API answer 401 as before.
      Self.logger.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")
      return ClaudeRefreshResolution(resolved: reloadedFromSource(base, now: now) ?? base)
    }
  }

  private enum StaleWriteResolution {
    case resolved(ClaudeRefreshResolution)
    /// The stored pair is the entered generation and provably still
    /// exchangeable — either it was never consumed, or its exchange showed
    /// the endpoint keeps the token alive.
    case exchange(ResolvedClaudeCredentials)
  }

  /// The source was rewritten while a refreshed pair was in hand (its guarded
  /// write was rejected as stale). A pair still riding the token this exchange
  /// rotated away is superseded by the grant; a different login/generation is
  /// authoritative and makes the queued grant obsolete.
  private func resolvedStaleWrite(
    _ pending: ClaudePendingGrant,
    enteredWith refreshToken: String,
    fallback: ResolvedClaudeCredentials,
    now: Date
  ) async -> StaleWriteResolution {
    guard let current = try? ClaudeCredentialsStore.load(
      source: fallback.source,
      capturedAccounts: capturedAccounts
    ) else {
      // The reread failed outright (not just moved on): the grant may hold
      // the only refresh token that still works, so keep it queued for the
      // next transaction and fetch with it in the meantime.
      await rememberPending(pending, source: fallback.source)
      return .resolved(ClaudeRefreshResolution(resolved: inMemory(fallback, pending.grant)))
    }
    let stored = ResolvedClaudeCredentials(credentials: current, source: fallback.source)
    if current.accessToken == pending.grant.accessToken {
      removeDurableGrantIfMatching(pending, source: fallback.source)
      return .resolved(ClaudeRefreshResolution(
        resolved: stored,
        acceptedGrant: fallback.source.isCaptured ? nil : pending
      ))
    }
    if pending.supersedes(
      accessToken: current.accessToken,
      refreshToken: current.refreshToken
    ) {
      return await .resolved(supersede(pending, stored: stored, now: now))
    }
    // The grant is obsolete on the remaining paths — clear any durable copy
    // so it isn't retried (against a pair that has moved on) every launch.
    removeDurableGrantIfMatching(pending, source: fallback.source)
    guard current.isExpired(now: now) else {
      return .resolved(ClaudeRefreshResolution(resolved: stored))
    }
    if current.refreshToken != refreshToken {
      return await .resolved(ClaudeRefreshResolution(
        resolved: refreshIfExpired(stored, now: now)
      ))
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
  ) async -> ClaudeRefreshResolution {
    let reapplied = pending.rebased(replacing: stored.credentials.accessToken)
    if let applied = await persisted(reapplied, resolved: stored) {
      guard let installed = try? ClaudeCredentialsStore.load(
        source: stored.source,
        capturedAccounts: capturedAccounts
      ), installed.accessToken == pending.grant.accessToken else {
        // `persisted` also returns the in-memory grant after a transient write
        // failure. Keep the original durable owner until the source proves it
        // accepted the rebased grant.
        return applied
      }
      removeDurableGrantIfMatching(pending, source: stored.source)
      return ClaudeRefreshResolution(
        resolved: applied.resolved,
        acceptedGrant: stored.source.isCaptured ? nil : pending
      )
    }
    // Yet another concurrent write landed; at some point theirs is the truth.
    return ClaudeRefreshResolution(
      resolved: reloadedFromSource(stored, now: now) ?? inMemory(stored, pending.grant)
    )
  }

  /// Persists the pending grant and returns the credentials to fetch with,
  /// or nil when the source holds a different pair than the grant replaces.
  /// A write failure keeps a consumed rotating grant queued for retry and
  /// still returns it: the rotation already happened server-side, so the
  /// in-memory pair is the freshest one there is.
  private func persisted(
    _ pending: ClaudePendingGrant,
    resolved: ResolvedClaudeCredentials
  ) async -> ClaudeRefreshResolution? {
    var acceptedGrant: ClaudePendingGrant?
    do {
      try persister.persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        to: resolved.source
      )
      // The source holds the grant now; any durable copy is obsolete.
      removeDurableGrantIfMatching(pending, source: resolved.source)
      if case .claudeKeychain = resolved.source {
        acceptedGrant = pending
      } else if case .claudeCredentialsFile = resolved.source {
        acceptedGrant = pending
      }
    } catch ClaudeCredentialPersistError.staleSource {
      return nil
    } catch {
      // The refresh already happened server-side, so dropping the fetch
      // wouldn't undo the rotation — continue with the in-memory pair and
      // queue any grant whose consumed refresh token can no longer recover it.
      Self.logger.error("Persisting refreshed tokens failed: \(error.localizedDescription, privacy: .public)")
      await rememberPending(pending, source: resolved.source)
    }
    return ClaudeRefreshResolution(
      resolved: inMemory(resolved, pending.grant),
      // The live source's guarded write accepted this exact generation. The
      // coordinator shares this proof with every joined caller; each verified
      // saved-account link mirrors it after the transaction returns.
      acceptedGrant: acceptedGrant
    )
  }
}
