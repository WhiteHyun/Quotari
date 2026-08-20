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

extension ClaudeUsageStrategy {
  /// Refreshing only once the token is actually (about to be) expired keeps
  /// the window for racing Claude Code's own refresh as small as possible.
  /// The whole refresh-persist-fallback transaction runs under the
  /// coordinator, keyed by source *and* refresh-token generation, so
  /// concurrent Quotari fetches can't burn the rotating token twice and a
  /// caller holding a newer pair never joins an older generation's run.
  func refreshResolutionIfExpired(
    _ resolved: ResolvedClaudeCredentials,
    now: Date,
    deniedAccessToken: String? = nil,
    capturedRegistryID: String? = nil
  ) async -> ClaudeRefreshResolution {
    let credentials = resolved.credentials
    let correlationSource = capturedRegistryID.map(ProviderCredentialSource.quotariRegistry)
    if let capturedRegistryID,
       await cachedMirrorBlocksRefresh(resolved, registryID: capturedRegistryID) {
      return ClaudeRefreshResolution(resolved: resolved)
    }
    let refreshNeeded = deniedAccessToken != nil || credentials.isExpired(now: now)
    guard case let .available(durablePending) = loadDurablePendingForLifecycle(
      resolved: resolved,
      correlationSource: correlationSource,
      now: now
    ) else {
      return ClaudeRefreshResolution(resolved: resolved)
    }
    guard refreshNeeded || durablePending != nil else {
      return ClaudeRefreshResolution(resolved: resolved)
    }
    if durablePending != nil {
      recordLifecycle(
        .pendingGrantFound,
        source: resolved.source,
        correlationSource: correlationSource,
        reason: .pendingGrant,
        timestamp: now
      )
    }
    recordRefreshSelection(
      source: resolved.source,
      correlationSource: correlationSource,
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
        now: now,
        correlationSource: correlationSource
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
    now: Date,
    correlationSource: ProviderCredentialSource?
  ) async -> ClaudeRefreshResolution {
    var base = resolved
    // Retry a rotated pair before submitting its burned token again.
    if let pending = await takePending(source: resolved.source, durablePending: durablePending) {
      if let retried = await persisted(
        pending,
        resolved: base,
        correlationSource: correlationSource
      ) {
        return retried
      }
      switch await resolvedStaleWrite(
        pending,
        enteredWith: pending.consumedRefreshToken,
        fallback: base,
        now: now,
        correlationSource: correlationSource
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
    return await exchanged(ClaudeRefreshExchangeRequest(
      base: base,
      refreshToken: refreshToken,
      deniedAccessToken: deniedAccessToken,
      now: now,
      correlationSource: correlationSource
    ), refresher: refresher)
  }
}
