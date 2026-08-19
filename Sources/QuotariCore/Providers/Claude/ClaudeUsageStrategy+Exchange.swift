import Foundation
import os

struct ClaudeRefreshExchangeRequest {
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
      timestamp: request.now
    )
    do {
      let grant = try await refresher.refresh(
        refreshToken: request.refreshToken,
        scopes: request.base.credentials.scopes,
        now: request.now
      )
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
      reason: request.reason
    )
    let pending = ClaudePendingGrant(
      grant: grant,
      previousAccessToken: request.base.credentials.accessToken,
      consumedRefreshToken: request.refreshToken
    )
    if let updated = await persisted(
      pending,
      resolved: request.base,
      correlationSource: request.correlationSource
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
    recordLifecycle(
      .refreshFailed,
      source: request.base.source,
      correlationSource: request.correlationSource,
      reason: request.reason,
      failure: .classify(error)
    )
    let reloaded = reloadedFromSource(request.base, now: request.now)
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
}
