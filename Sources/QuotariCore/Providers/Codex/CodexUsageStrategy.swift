import Foundation
import os

private struct LoadedCodexCredentials: Sendable {
  var credentials: CodexCredentials
  var source: ProviderCredentialSource
}

/// Fetches Codex usage over OAuth from its configured file/keyring/auto auth
/// backend, calls the usage endpoint, and parses via the generic window
/// mapper. Not available when no credentials are present, so the pipeline can
/// fall through.
///
/// Saved (registry) accounts refresh their own expired access tokens against
/// the OAuth token endpoint and persist the rotated pair back to the registry.
/// Live CLI credentials are left alone — that store is Codex's to manage, and
/// racing its refresh loop could burn the rotating token pair.
public struct CodexUsageStrategy: ProviderFetchStrategy {
  public let id = "codex.oauth"
  public let kind: ProviderFetchKind = .oauth

  private static let logger = Logger(subsystem: "com.quotari.QuotariCore", category: "codex-oauth")

  private let transport: any ProviderHTTPTransport
  private let loadAutomaticCredentials: @Sendable () throws -> LoadedCodexCredentials
  private let usageURL: URL
  private let refresher: (any CodexTokenRefreshing)?
  private let persister: any CodexCredentialPersisting
  let capturedAccounts: CapturedAccountStore
  let refreshCoordinator: CodexTokenRefreshCoordinator

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
    loadCredentials: (@Sendable () throws -> CodexCredentials)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    codexKeychainRead: (@Sendable (String, String) throws -> Data?)? = nil,
    refresher: (any CodexTokenRefreshing)? = CodexTokenRefresher(),
    persister: (any CodexCredentialPersisting)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    refreshCoordinator: CodexTokenRefreshCoordinator = .shared
  ) {
    let keychainRead = codexKeychainRead ?? { service, account in
      try KeychainItemStore(account: account).read(service: service)
    }
    let storage = CodexAuthStorage(
      environment: environment,
      home: home,
      keychainRead: keychainRead
    )
    let fallbackSource = ProviderCredentialSource.codexAuthFile(path: storage.authFileURL.path)
    self.transport = transport
    self.usageURL = usageURL
    if let loadCredentials {
      loadAutomaticCredentials = {
        try LoadedCodexCredentials(credentials: loadCredentials(), source: fallbackSource)
      }
    } else {
      loadAutomaticCredentials = {
        let snapshot = try storage.snapshot()
        guard let payload = snapshot.payload else { throw CodexCredentialsError.notFound }
        return try LoadedCodexCredentials(
          credentials: CodexCredentialsStore.parse(payload),
          source: snapshot.source
        )
      }
    }
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
    let loaded = try credentials(for: context)
    var credentials = loaded.credentials
    guard case let .quotariRegistry(id) = context.account?.credentialSource else {
      return try await usageResult(
        with: credentials,
        credentialSource: loaded.source,
        context: context
      )
    }
    credentials = await refreshIfExpired(credentials, registryID: id, now: context.now)
    do {
      return try await usageResult(
        with: credentials,
        credentialSource: loaded.source,
        context: context
      )
    } catch ProviderHTTPError.unauthorized {
      // A saved account can be denied before its local expiry says so (token
      // revoked early, or an `exp` claim we can't read). The registry still
      // holds a refresh token, so force one refresh and retry once.
      let retried = await refreshIfExpired(
        credentials,
        registryID: id,
        now: context.now,
        deniedAccessToken: credentials.accessToken
      )
      guard retried.accessToken != credentials.accessToken else {
        throw ProviderHTTPError.unauthorized
      }
      return try await usageResult(
        with: retried,
        credentialSource: loaded.source,
        context: context
      )
    }
  }

  private func usageResult(
    with credentials: CodexCredentials,
    credentialSource: ProviderCredentialSource,
    context: ProviderFetchContext
  ) async throws -> ProviderFetchResult {
    var headers: [String: String] = [:]
    if let account = credentials.accountID {
      headers["chatgpt-account-id"] = account
    }
    let data = try await transport.getJSON(url: usageURL, bearer: credentials.accessToken, headers: headers)
    var usage = try CodexUsageParser.parse(data, provider: context.provider, now: context.now)
    if usage.account == nil {
      usage.account = credentials.email
    }
    let account = ProviderAccount(
      provider: context.provider,
      displayName: credentials.email ?? credentials.accountID ?? "Codex account",
      detail: nil,
      credentialSource: credentialSource,
      credentialIdentity: credentials.accountID
        ?? credentials.email
        ?? credentials.refreshToken
        ?? credentials.accessToken
    )
    return ProviderFetchResult(
      usage: usage,
      sourceLabel: "Codex",
      credentialScopeID: account.credentialScopeID
    )
  }

  public func shouldFallback(on error: Error) -> Bool {
    if let fetchError = error as? ProviderFetchError,
       case .selectedCredentialUnavailable = fetchError {
      return false
    }
    // Auth failures won't be fixed by retrying another Codex strategy.
    return !(error is ProviderHTTPError)
  }

  private func credentials(for context: ProviderFetchContext) throws -> LoadedCodexCredentials {
    if let account = context.account {
      do {
        return try LoadedCodexCredentials(
          credentials: CodexCredentialsStore.load(
            source: account.credentialSource,
            capturedAccounts: capturedAccounts
          ),
          source: account.credentialSource
        )
      } catch {
        throw ProviderFetchError.selectedCredentialUnavailable(context.provider)
      }
    }
    return try loadAutomaticCredentials()
  }
}

// MARK: - Saved-account token refresh

private extension CodexUsageStrategy {
  /// Refreshing only once the token is actually (about to be) expired keeps
  /// refresh traffic to the minimum that keeps a saved account usable. The
  /// whole refresh-persist-fallback transaction runs under the coordinator,
  /// keyed by registry id *and* refresh-token generation, so concurrent
  /// Quotari fetches can't burn the rotating token twice.
  private func refreshIfExpired(
    _ credentials: CodexCredentials,
    registryID: String,
    now: Date,
    deniedAccessToken: String? = nil
  ) async -> CodexCredentials {
    guard deniedAccessToken != nil || credentials.isExpired(now: now),
          let refreshToken = credentials.refreshToken,
          let refresher
    else { return credentials }
    let durablePending: CodexPendingGrant?
    do {
      durablePending = try loadDurablePending(registryID: registryID)
    } catch {
      // A transient keychain failure is not absence. Do not submit a token
      // that may already have been consumed while its replacement is hidden.
      Self.logger.error("Reading a pending Codex grant failed: \(error.localizedDescription, privacy: .public)")
      return credentials
    }
    return await refreshCoordinator.resolve(key: "\(registryID)#\(refreshToken)") {
      // Double-check inside the transaction: a previous transaction may have
      // persisted a fresh pair while we waited. A pair the endpoint just
      // denied doesn't count, whatever its local expiry claims.
      if let reloaded = reloadedFromRegistry(id: registryID, now: now),
         reloaded.accessToken != deniedAccessToken {
        return reloaded
      }
      var base = credentials
      // A pair from an earlier exchange whose write-back failed: that exchange
      // already consumed the stored refresh token server-side, so retry the
      // write before submitting the burned token again.
      if let pending = await takePending(registryID: registryID, durablePending: durablePending) {
        if let retried = await persisted(pending, credentials: base, registryID: registryID, now: now) {
          return retried.credentials
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
      var grant = try await refresher.refresh(refreshToken: refreshToken)
      grant.refreshedAt = now
      let pending = CodexPendingGrant(
        grant: grant,
        previousAccessToken: base.accessToken,
        consumedRefreshToken: refreshToken
      )
      if let updated = await persisted(pending, credentials: base, registryID: registryID, now: now) {
        return updated.credentials
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

  private struct PersistedGrant {
    let credentials: CodexCredentials
    let isDurablyRecoverable: Bool
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
    ) else {
      // The reread failed outright (not just moved on): the grant may hold
      // the only refresh token that still works, so keep it queued for the
      // next transaction and fetch with it in the meantime.
      await rememberPending(pending, registryID: registryID)
      return .resolved(inMemory(fallback, pending.grant))
    }
    if current.refreshToken == pending.consumedRefreshToken, pending.rotatedRefreshToken {
      return await .resolved(supersede(pending, stored: current, registryID: registryID, now: now))
    }
    // The grant is obsolete on the remaining paths — clear any durable copy
    // so it isn't retried (against a pair that has moved on) every launch.
    removePendingIfMatching(pending, registryID: registryID)
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
      if applied.isDurablyRecoverable {
        removePendingIfMatching(pending, registryID: registryID)
      }
      return applied.credentials
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
  ) async -> PersistedGrant? {
    do {
      try persister.persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        toRegistryAccount: registryID
      )
      // The registry holds the grant now; any durable copy is obsolete.
      removePendingIfMatching(pending, registryID: registryID)
    } catch CodexCredentialPersistError.staleSource {
      return nil
    } catch {
      Self.logger.error("Persisting refreshed Codex tokens failed: \(error.localizedDescription, privacy: .public)")
      let isDurablyRecoverable = await rememberPending(pending, registryID: registryID)
      // The write failed, so the registry still holds the old (possibly
      // denied) pair — the in-memory grant is the only fresh one.
      return PersistedGrant(
        credentials: inMemory(credentials, pending.grant),
        isDurablyRecoverable: isDurablyRecoverable
      )
    }
    // Re-read for the fully derived fields (JWT expiry, id_token email); fall
    // back to patching in memory when the registry read fails.
    return PersistedGrant(
      credentials: reloadedFromRegistry(id: registryID, now: now) ?? inMemory(credentials, pending.grant),
      isDurablyRecoverable: true
    )
  }
}
