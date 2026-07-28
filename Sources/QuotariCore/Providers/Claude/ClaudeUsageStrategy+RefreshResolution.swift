import Foundation

extension ClaudeUsageStrategy {
  func resolvedCredentials(
    from refresh: ClaudeRefreshResolution
  ) async throws -> ResolvedClaudeCredentials {
    if let terminalError = refresh.terminalError {
      throw terminalError
    }
    let resolved = refresh.resolved
    if let previousAccessToken = refresh.rotatedFromAccessToken {
      await rateLimitGate.transferCooldown(
        from: previousAccessToken,
        to: resolved.credentials.accessToken
      )
    }
    return resolved
  }
}
