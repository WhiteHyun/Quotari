import Foundation
import os

/// Fetches Codex usage over OAuth: reads `~/.codex/auth.json`, calls the usage
/// endpoint, and parses via the generic window mapper. Not available when no
/// credentials are present, so the pipeline can fall through.
///
/// Saved (registry) accounts refresh their own expired access tokens against
/// the OAuth token endpoint and persist the rotated pair back to the registry.
/// Live `auth.json` credentials are left alone — that file is the Codex CLI's
/// to manage, and racing its refresh loop could burn the rotating token pair.
public struct CodexUsageStrategy: ProviderFetchStrategy {
  public let id = "codex.oauth"
  public let kind: ProviderFetchKind = .oauth

  private static let logger = Logger(subsystem: "com.quotari.QuotariCore", category: "codex-oauth")

  private let transport: any ProviderHTTPTransport
  private let loadCredentials: @Sendable () throws -> CodexCredentials
  private let usageURL: URL
  private let refresher: (any CodexTokenRefreshing)?
  private let persister: any CodexCredentialPersisting
  private let capturedAccounts: CapturedAccountStore
  private let refreshCoordinator: CodexTokenRefreshCoordinator

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
    loadCredentials: @escaping @Sendable () throws -> CodexCredentials = { try CodexCredentialsStore.load() },
    refresher: (any CodexTokenRefreshing)? = CodexTokenRefresher(),
    persister: (any CodexCredentialPersisting)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    refreshCoordinator: CodexTokenRefreshCoordinator = .shared
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.loadCredentials = loadCredentials
    self.refresher = refresher
    self.persister = persister ?? CodexCredentialsWriter(capturedAccounts: capturedAccounts)
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
    var credentials = try credentials(for: context)
    if case let .quotariRegistry(id) = context.account?.credentialSource {
      credentials = await refreshIfExpired(credentials, registryID: id, now: context.now)
    }
    var headers: [String: String] = [:]
    if let account = credentials.accountID {
      headers["chatgpt-account-id"] = account
    }
    let data = try await transport.getJSON(url: usageURL, bearer: credentials.accessToken, headers: headers)
    var usage = try CodexUsageParser.parse(data, provider: context.provider, now: context.now)
    if usage.account == nil {
      usage.account = credentials.email
    }
    return ProviderFetchResult(usage: usage, sourceLabel: "Codex")
  }

  public func shouldFallback(on error: Error) -> Bool {
    if let fetchError = error as? ProviderFetchError,
       case .selectedCredentialUnavailable = fetchError {
      return false
    }
    // Auth failures won't be fixed by retrying another Codex strategy.
    return !(error is ProviderHTTPError)
  }

  private func credentials(for context: ProviderFetchContext) throws -> CodexCredentials {
    if let account = context.account {
      do {
        return try CodexCredentialsStore.load(
          source: account.credentialSource,
          capturedAccounts: capturedAccounts
        )
      } catch {
        throw ProviderFetchError.selectedCredentialUnavailable(context.provider)
      }
    }
    return try loadCredentials()
  }

  /// Refreshing only once the token is actually (about to be) expired keeps
  /// refresh traffic to the minimum that keeps a saved account usable. The
  /// whole refresh-persist-fallback transaction runs under the coordinator,
  /// keyed by registry id *and* refresh-token generation, so concurrent
  /// Quotari fetches can't burn the rotating token twice.
  private func refreshIfExpired(
    _ credentials: CodexCredentials,
    registryID: String,
    now: Date
  ) async -> CodexCredentials {
    guard credentials.isExpired(now: now),
          let refreshToken = credentials.refreshToken,
          let refresher
    else { return credentials }
    return await refreshCoordinator.resolve(key: "\(registryID)#\(refreshToken)") {
      // Double-check inside the transaction: a previous transaction may have
      // persisted a fresh pair while we waited.
      if let reloaded = reloadedFromRegistry(id: registryID, now: now) {
        return reloaded
      }
      var base = credentials
      // A pair from an earlier exchange whose write-back failed: that exchange
      // already consumed the stored refresh token server-side, so retry the
      // write before submitting the burned token again.
      if let pending = await refreshCoordinator.takeUnpersisted(registryID: registryID) {
        if let retried = await persisted(pending, credentials: base, registryID: registryID, now: now) {
          return retried
        }
        switch await resolvedStaleWrite(
          pending,
          enteredWith: refreshToken,
          fallback: base,
          registryID: registryID,
          now: now
        ) {
        case let .resolved(resolved):
          return resolved
        case let .exchange(current):
          base = current
        }
      }
      return await exchanged(base, refreshToken: refreshToken, refresher: refresher, registryID: registryID, now: now)
    }
  }

  /// One fresh exchange of `refreshToken`, persisted over `base`. On a stale
  /// write the shared resolution decides; a failed exchange falls back to the
  /// stored pair and lets the API answer 401 as before.
  private func exchanged(
    _ base: CodexCredentials,
    refreshToken: String,
    refresher: any CodexTokenRefreshing,
    registryID: String,
    now: Date
  ) async -> CodexCredentials {
    do {
      let grant = try await refresher.refresh(refreshToken: refreshToken)
      let pending = CodexPendingGrant(
        grant: grant,
        previousAccessToken: base.accessToken,
        consumedRefreshToken: refreshToken
      )
      if let updated = await persisted(pending, credentials: base, registryID: registryID, now: now) {
        return updated
      }
      Self.logger.notice("Saved Codex credentials changed during refresh; resolving against the newer pair.")
      switch await resolvedStaleWrite(
        pending,
        enteredWith: refreshToken,
        fallback: base,
        registryID: registryID,
        now: now
      ) {
      case let .resolved(resolved):
        return resolved
      case let .exchange(current):
        // Same still-valid (non-rotating) token: their write stays stored
        // and can refresh itself later; the grant still serves this fetch.
        return current.isExpired(now: now) ? inMemory(current, grant) : current
      }
    } catch {
      Self.logger.error("Codex token refresh failed: \(error.localizedDescription, privacy: .public)")
      return reloadedFromRegistry(id: registryID, now: now) ?? base
    }
  }

  private enum StaleWriteResolution {
    case resolved(CodexCredentials)
    /// The stored pair is the entered generation and provably still
    /// exchangeable — either it was never consumed, or its exchange showed
    /// the endpoint keeps the token alive. A fresh exchange is safe and
    /// never risks overwriting a newer concurrent write.
    case exchange(CodexCredentials)
  }

  /// The registry was rewritten while a refreshed pair was in hand (its
  /// guarded write was rejected as stale). Decides what wins against the
  /// pair stored now: a pair riding a token the exchange rotated away can
  /// never refresh again (superseded by the grant); a different generation
  /// restarts re-keyed so concurrent fetches of it share one exchange.
  private func resolvedStaleWrite(
    _ pending: CodexPendingGrant,
    enteredWith refreshToken: String,
    fallback: CodexCredentials,
    registryID: String,
    now: Date
  ) async -> StaleWriteResolution {
    guard let current = try? CodexCredentialsStore.load(
      source: .quotariRegistry(id: registryID),
      capturedAccounts: capturedAccounts
    ) else { return .resolved(inMemory(fallback, pending.grant)) }
    if current.refreshToken == pending.consumedRefreshToken, pending.rotatedRefreshToken {
      return await .resolved(supersede(pending, stored: current, registryID: registryID, now: now))
    }
    if current.refreshToken != refreshToken {
      return await .resolved(refreshIfExpired(current, registryID: registryID, now: now))
    }
    return .exchange(current)
  }

  /// The stored pair rides a refresh token an exchange rotated away — it can
  /// never refresh again, so the pending grant supersedes it no matter who
  /// wrote it. Re-applies the grant on top of the stored payload.
  private func supersede(
    _ pending: CodexPendingGrant,
    stored: CodexCredentials,
    registryID: String,
    now: Date
  ) async -> CodexCredentials {
    let reapplied = CodexPendingGrant(
      grant: pending.grant,
      previousAccessToken: stored.accessToken,
      consumedRefreshToken: pending.consumedRefreshToken
    )
    if let applied = await persisted(reapplied, credentials: stored, registryID: registryID, now: now) {
      return applied
    }
    // Yet another concurrent write landed; at some point theirs is the truth.
    return reloadedFromRegistry(id: registryID, now: now) ?? inMemory(stored, pending.grant)
  }

  /// Persists the pending grant and returns the credentials to fetch with,
  /// or nil when the registry holds a different pair than the grant replaces
  /// (someone re-captured or refreshed concurrently — their pair wins). A
  /// write failure keeps the grant queued for retry and still returns it:
  /// the rotation already happened server-side, so the in-memory pair is the
  /// freshest one there is.
  private func persisted(
    _ pending: CodexPendingGrant,
    credentials: CodexCredentials,
    registryID: String,
    now: Date
  ) async -> CodexCredentials? {
    do {
      try persister.persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        toRegistryAccount: registryID
      )
    } catch CodexCredentialPersistError.staleSource {
      return nil
    } catch {
      Self.logger.error("Persisting refreshed Codex tokens failed: \(error.localizedDescription, privacy: .public)")
      await refreshCoordinator.rememberUnpersisted(pending, registryID: registryID)
    }
    // Re-read for the fully derived fields (JWT expiry, id_token email); fall
    // back to patching in memory when the registry read fails.
    return reloadedFromRegistry(id: registryID, now: now) ?? inMemory(credentials, pending.grant)
  }

  /// The credentials patched with a grant that isn't (or isn't yet) stored —
  /// good for fetching with while the registry catches up.
  private func inMemory(_ credentials: CodexCredentials, _ grant: CodexTokenGrant) -> CodexCredentials {
    var updated = credentials
    updated.accessToken = grant.accessToken
    updated.refreshToken = grant.refreshToken ?? credentials.refreshToken
    updated.expiresAt = CodexCredentialsStore.jwtExpiry(of: grant.accessToken)
    return updated
  }

  private func reloadedFromRegistry(id: String, now: Date) -> CodexCredentials? {
    guard let reloaded = try? CodexCredentialsStore.load(
      source: .quotariRegistry(id: id),
      capturedAccounts: capturedAccounts
    ), !reloaded.isExpired(now: now)
    else { return nil }
    return reloaded
  }
}
