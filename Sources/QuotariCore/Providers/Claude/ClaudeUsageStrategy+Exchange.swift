import Foundation
import os

struct ClaudeRefreshExchangeRequest {
  let operationID = UUID()
  let base: ResolvedClaudeCredentials
  let refreshToken: String
  let deniedAccessToken: String?
  let now: Date
  let correlationSource: ProviderCredentialSource?

  var reason: CredentialLifecycleEvent.Reason {
    deniedAccessToken == nil ? .expired : .unauthorized
  }
}

extension ClaudeUsageStrategy {
  /// One fresh exchange persisted over the source. On a stale write the
  /// shared resolution decides; a failed exchange lets the API answer 401.
  func exchanged(
    _ request: ClaudeRefreshExchangeRequest,
    refresher: any ClaudeTokenRefreshing
  ) async -> ClaudeRefreshResolution {
    recordLifecycle(
      .refreshStarted,
      source: request.base.source,
      correlationSource: request.correlationSource,
      reason: request.reason,
      timestamp: request.now,
      diagnostic: exchangeDiagnostic(request)
    )
    do {
      let context = ClaudeRefreshDiagnosticContext { status, code in
        var diagnostic = exchangeDiagnostic(request)
        diagnostic.httpStatus = status
        diagnostic.oauthError = code
        recordLifecycle(
          .tokenEndpointResponded, source: request.base.source,
          correlationSource: request.correlationSource, diagnostic: diagnostic
        )
      }
      let grant = try await ClaudeRefreshDiagnosticContext.$current.withValue(context) {
        try await refresher.refresh(
          refreshToken: request.refreshToken,
          scopes: request.base.credentials.scopes,
          now: request.now
        )
      }
      return await resolvedExchange(grant, request: request)
    } catch {
      return failedExchange(error, request: request)
    }
  }

  private func resolvedExchange(
    _ grant: ClaudeTokenGrant,
    request: ClaudeRefreshExchangeRequest
  ) async -> ClaudeRefreshResolution {
    recordLifecycle(
      .refreshSucceeded,
      source: request.base.source,
      correlationSource: request.correlationSource,
      reason: request.reason,
      diagnostic: exchangeDiagnostic(request, grant: grant)
    )
    let pending = ClaudePendingGrant(
      grant: grant,
      previousAccessToken: request.base.credentials.accessToken,
      consumedRefreshToken: request.refreshToken
    )
    if let updated = await persisted(
      pending,
      resolved: request.base,
      correlationSource: request.correlationSource,
      operationID: request.operationID
    ) {
      return updated
    }
    switch await resolvedStaleWrite(
      pending,
      enteredWith: request.refreshToken,
      fallback: request.base,
      now: request.now,
      correlationSource: request.correlationSource
    ) {
    case let .resolved(outcome):
      return outcome
    case let .exchange(current):
      // A still-valid non-rotating token leaves the concurrent write stored;
      // the newly issued grant can still serve this fetch in memory.
      return ClaudeRefreshResolution(
        resolved: current.credentials.isExpired(now: request.now)
          ? inMemory(current, grant)
          : current,
        rotatedFromAccessToken: pending.previousAccessToken
      )
    }
  }

  private func failedExchange(
    _ error: Error,
    request: ClaudeRefreshExchangeRequest
  ) -> ClaudeRefreshResolution {
    // Claude Code may have rotated first. Re-read once before giving up.
    Self.logger.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")
    let reloaded = reloadedFromSource(request.base, now: request.now)
    let stored = try? reloadCredentials(request.base.source)
    var diagnostic = exchangeDiagnostic(request)
    diagnostic.storedGeneration = stored.map { credentialLifecycleLogger.generation($0) }
    diagnostic.storageReadFailed = stored == nil
    recordLifecycle(
      .refreshFailed,
      source: request.base.source,
      correlationSource: request.correlationSource,
      reason: request.reason,
      failure: .classify(error),
      diagnostic: diagnostic
    )
    if let reloaded,
       reloaded.credentials.accessToken != request.deniedAccessToken {
      return ClaudeRefreshResolution(resolved: reloaded)
    }
    return ClaudeRefreshResolution(
      resolved: reloaded ?? request.base,
      terminalError: (error as? ClaudeTokenRefreshError)?.requiresReauthentication == true
        ? .reauthenticationRequired
        : nil
    )
  }

  private func exchangeDiagnostic(
    _ request: ClaudeRefreshExchangeRequest,
    grant: ClaudeTokenGrant? = nil
  ) -> CredentialLifecycleDiagnostic {
    var received = request.base.credentials
    if let grant {
      received.accessToken = grant.accessToken
      received.refreshToken = grant.refreshToken ?? request.refreshToken
      received.expiresAt = grant.expiresAt
    }
    return CredentialLifecycleDiagnostic(
      operationID: request.operationID,
      generation: credentialLifecycleLogger.generation(request.base.credentials),
      receivedGeneration: grant.map { _ in credentialLifecycleLogger.generation(received) }
    )
  }
}
