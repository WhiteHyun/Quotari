import Foundation
import os

/// Fetches Claude usage over OAuth from the environment, Claude Code keychain,
/// or `~/.claude/.credentials.json`; unavailable sources fall through.
/// Expired access tokens are refreshed against the OAuth token endpoint and
/// the rotated pair is written back to the source, so Claude Code keeps
/// working with the same refresh token.
public struct ClaudeUsageStrategy: ProviderFetchStrategy {
  public let id = "claude.oauth"
  public let kind: ProviderFetchKind = .oauth

  static let logger = Logger(subsystem: "com.quotari.QuotariCore", category: "claude-oauth")

  let transport: any ProviderHTTPTransport
  let usageURL: URL
  private let resolveCredentials: @Sendable () throws -> ResolvedClaudeCredentials
  let reloadCredentials: @Sendable (ProviderCredentialSource) throws -> ClaudeCredentials
  private let refresher: (any ClaudeTokenRefreshing)?
  let persister: any ClaudeCredentialPersisting
  let capturedAccounts: CapturedAccountStore
  let refreshCoordinator: ClaudeTokenRefreshCoordinator
  let rateLimitGate: ClaudeUsageRateLimitGate
  let credentialLifecycleLogger: CredentialLifecycleLogger

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
    resolveCredentials: @escaping @Sendable () throws -> ResolvedClaudeCredentials = {
      try ClaudeCredentialsStore.loadResolved()
    },
    reloadCredentials: (@Sendable (ProviderCredentialSource) throws -> ClaudeCredentials)? = nil,
    refresher: (any ClaudeTokenRefreshing)? = ClaudeTokenRefresher(),
    persister: (any ClaudeCredentialPersisting)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    mirroredCredentialsFileURL: URL? = nil,
    refreshCoordinator: ClaudeTokenRefreshCoordinator = .shared,
    rateLimitGate: ClaudeUsageRateLimitGate = .shared,
    credentialLifecycleLogger: CredentialLifecycleLogger = .disabled
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.resolveCredentials = resolveCredentials
    self.reloadCredentials = reloadCredentials ?? { source in
      try ClaudeCredentialsStore.load(source: source, capturedAccounts: capturedAccounts)
    }
    self.refresher = refresher
    self.persister = persister ?? ClaudeCredentialsWriter(
      capturedAccounts: capturedAccounts,
      mirroredCredentialsFileURL: mirroredCredentialsFileURL
    )
    self.capturedAccounts = capturedAccounts
    self.refreshCoordinator = refreshCoordinator
    self.rateLimitGate = rateLimitGate
    self.credentialLifecycleLogger = credentialLifecycleLogger
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
    let refresh = await refreshResolutionIfExpired(
      resolved,
      now: context.now,
      capturedRegistryID: context.capturedRegistryID
    )
    resolved = try await resolvedCredentials(from: refresh)
    if context.interaction == .background,
       let blockedUntil = await rateLimitGate.blockedUntil(
         for: resolved.credentials.accessToken
       ) {
      throw ProviderHTTPError.rateLimited(retryAfter: blockedUntil)
    }
    let transitionSources = credentialTransitionSourceScopeIDs(
      refresh.acceptedGrant,
      source: resolved.source
    )
    guard case .quotariRegistry = resolved.source else {
      return try await liveUsageResult(
        with: resolved,
        context: context,
        credentialTransitionSourceScopeIDs: transitionSources
      )
    }
    do {
      return try await usageResult(with: resolved, context: context)
    } catch ProviderHTTPError.unauthorized {
      // A saved account can be denied before its stored expiry says so (token
      // revoked early). The registry still holds a refresh token, so force
      // one refresh and retry once.
      let retried = await refreshResolutionIfExpired(
        resolved,
        now: context.now,
        deniedAccessToken: resolved.credentials.accessToken,
        capturedRegistryID: context.capturedRegistryID
      )
      let retriedCredentials = try await resolvedCredentials(from: retried)
      guard retriedCredentials.credentials.accessToken != resolved.credentials.accessToken else {
        throw ProviderHTTPError.unauthorized
      }
      return try await usageResult(with: retriedCredentials, context: context)
    }
  }

  private func liveUsageResult(
    with resolved: ResolvedClaudeCredentials,
    context: ProviderFetchContext,
    credentialTransitionSourceScopeIDs: Set<String>
  ) async throws -> ProviderFetchResult {
    do {
      return try await usageResult(
        with: resolved,
        context: context,
        credentialTransitionSourceScopeIDs: credentialTransitionSourceScopeIDs
      )
    } catch {
      guard !credentialTransitionSourceScopeIDs.isEmpty else { throw error }
      let target = ProviderAccount(
        provider: context.provider,
        displayName: "Claude Code",
        detail: nil,
        credentialSource: resolved.source,
        credentialIdentity: resolved.credentials.accessToken
      )
      throw ProviderFetchTransitionError(
        underlying: error,
        credentialTransitionTargetScopeID: target.credentialScopeID,
        credentialTransitionSourceScopeIDs: credentialTransitionSourceScopeIDs
      )
    }
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
  private func refreshResolutionIfExpired(
    _ resolved: ResolvedClaudeCredentials,
    now: Date,
    deniedAccessToken: String? = nil,
    capturedRegistryID: String? = nil
  ) async -> ClaudeRefreshResolution {
    let credentials = resolved.credentials
    if let capturedRegistryID,
       await cachedMirrorBlocksRefresh(resolved, registryID: capturedRegistryID) {
      return ClaudeRefreshResolution(resolved: resolved)
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
      recordLifecycle(.pendingGrantReadFailed, source: resolved.source, failure: .inputOutput, timestamp: now)
      return ClaudeRefreshResolution(resolved: resolved)
    }
    guard refreshNeeded || durablePending != nil else {
      return ClaudeRefreshResolution(resolved: resolved)
    }
    if durablePending != nil {
      recordLifecycle(.pendingGrantFound, source: resolved.source, reason: .pendingGrant, timestamp: now)
    }
    recordRefreshSelection(
      source: resolved.source,
      denied: deniedAccessToken != nil,
      hasPendingGrant: durablePending != nil,
      timestamp: now
    )
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
    return resolution
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
      deniedAccessToken: deniedAccessToken,
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
    deniedAccessToken: String?,
    now: Date
  ) async -> ClaudeRefreshResolution {
    let reason: CredentialLifecycleEvent.Reason = deniedAccessToken == nil ? .expired : .unauthorized
    recordLifecycle(.refreshStarted, source: base.source, reason: reason, timestamp: now)
    do {
      let grant = try await refresher.refresh(
        refreshToken: refreshToken,
        scopes: base.credentials.scopes,
        now: now
      )
      recordLifecycle(.refreshSucceeded, source: base.source, reason: reason)
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
          resolved: current.credentials.isExpired(now: now) ? inMemory(current, grant) : current,
          rotatedFromAccessToken: pending.previousAccessToken
        )
      }
    } catch {
      // Claude Code may have rotated the token first; its fresher pair
      // will already be at the source, so re-read once before giving up.
      // If that doesn't help either, let the API answer 401 as before.
      Self.logger.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")
      recordLifecycle(.refreshFailed, source: base.source, reason: reason, failure: .classify(error))
      let reloaded = reloadedFromSource(base, now: now)
      if let reloaded,
         !reloaded.credentials.isExpired(now: now),
         reloaded.credentials.accessToken != deniedAccessToken {
        return ClaudeRefreshResolution(resolved: reloaded)
      }
      return ClaudeRefreshResolution(
        resolved: reloaded ?? base,
        terminalError: (error as? ClaudeTokenRefreshError)?.requiresReauthentication == true
          ? .reauthenticationRequired
          : nil
      )
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
      return .resolved(ClaudeRefreshResolution(
        resolved: inMemory(fallback, pending.grant),
        rotatedFromAccessToken: pending.previousAccessToken
      ))
    }
    let stored = ResolvedClaudeCredentials(credentials: current, source: fallback.source)
    if pending.matchesInstalledGeneration(
      accessToken: current.accessToken,
      refreshToken: current.refreshToken
    ) {
      removeDurableGrantIfMatching(pending, source: fallback.source)
      return .resolved(ClaudeRefreshResolution(
        resolved: stored,
        acceptedGrant: fallback.source.isCaptured ? nil : pending,
        rotatedFromAccessToken: pending.previousAccessToken
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
      return .resolved(ClaudeRefreshResolution(
        resolved: stored,
        rotatedFromAccessToken: current.refreshToken == refreshToken
          ? pending.previousAccessToken
          : nil
      ))
    }
    if current.refreshToken != refreshToken {
      return await .resolved(refreshResolutionIfExpired(stored, now: now))
    }
    return .exchange(stored)
  }
}
