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
  private let refreshCoordinator: ClaudeTokenRefreshCoordinator

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
    resolveCredentials: @escaping @Sendable () throws -> ResolvedClaudeCredentials = {
      try ClaudeCredentialsStore.loadResolved()
    },
    refresher: (any ClaudeTokenRefreshing)? = ClaudeTokenRefresher(),
    persister: any ClaudeCredentialPersisting = ClaudeCredentialsWriter(),
    refreshCoordinator: ClaudeTokenRefreshCoordinator = .shared
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.resolveCredentials = resolveCredentials
    self.refresher = refresher
    self.persister = persister
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
    let credentials = resolved.credentials
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
          credentials: ClaudeCredentialsStore.load(source: account.credentialSource),
          source: account.credentialSource
        )
      } catch {
        throw ProviderFetchError.selectedCredentialUnavailable(context.provider)
      }
    }
    return try resolveCredentials()
  }

  /// Refreshing only once the token is actually (about to be) expired keeps
  /// the window for racing Claude Code's own refresh as small as possible.
  /// The whole refresh-persist-fallback transaction runs under the
  /// coordinator, keyed by source *and* refresh-token generation, so
  /// concurrent Quotari fetches can't burn the rotating token twice and a
  /// caller holding a newer pair never joins an older generation's run.
  private func refreshIfExpired(
    _ resolved: ResolvedClaudeCredentials,
    now: Date
  ) async -> ResolvedClaudeCredentials {
    let credentials = resolved.credentials
    guard credentials.isExpired(now: now),
          let refreshToken = credentials.refreshToken,
          let refresher
    else { return resolved }
    let key = "\(resolved.source.stableID)#\(refreshToken)"
    return await refreshCoordinator.resolve(key: key) {
      // Double-check inside the transaction: a previous transaction (or
      // Claude Code itself) may have persisted a fresh pair while we waited.
      if let reloaded = reloadedFromSource(resolved, now: now) {
        return reloaded
      }
      do {
        let grant = try await refresher.refresh(
          refreshToken: refreshToken,
          scopes: credentials.scopes,
          now: now
        )
        return persistedCredentials(grant, resolved: resolved, now: now)
      } catch {
        // Claude Code may have rotated the token first; its fresher pair
        // will already be at the source, so re-read once before giving up.
        // If that doesn't help either, let the API answer 401 as before.
        Self.logger.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")
        return reloadedFromSource(resolved, now: now) ?? resolved
      }
    }
  }

  private func persistedCredentials(
    _ grant: ClaudeTokenGrant,
    resolved: ResolvedClaudeCredentials,
    now: Date
  ) -> ResolvedClaudeCredentials {
    do {
      try persister.persist(grant, replacing: resolved.credentials.accessToken, to: resolved.source)
    } catch ClaudeCredentialPersistError.staleSource {
      // Someone re-logged-in (or otherwise replaced the pair) since we read
      // it; their credentials are the truth now, not our refreshed grant.
      Self.logger.notice("Credential source changed during refresh; using its pair instead.")
      return reloadedFromSource(resolved, now: now) ?? resolved
    } catch {
      // The refresh already happened server-side, so dropping the fetch
      // wouldn't undo the rotation — continue with the in-memory pair.
      Self.logger.error("Persisting refreshed tokens failed: \(error.localizedDescription, privacy: .public)")
    }
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
    guard let reloaded = try? ClaudeCredentialsStore.load(source: resolved.source),
          !reloaded.isExpired(now: now)
    else { return nil }
    return ResolvedClaudeCredentials(credentials: reloaded, source: resolved.source)
  }
}
