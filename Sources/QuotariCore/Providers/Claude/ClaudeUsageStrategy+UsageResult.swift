import Foundation

extension ClaudeUsageStrategy {
  func usageResult(
    with resolved: ResolvedClaudeCredentials,
    context: ProviderFetchContext,
    credentialTransitionSourceScopeIDs: Set<String> = []
  ) async throws -> ProviderFetchResult {
    let credentials = resolved.credentials
    let data: Data
    do {
      data = try await transport.getJSON(
        url: usageURL,
        bearer: credentials.accessToken,
        headers: ["anthropic-beta": "oauth-2025-04-20"]
      )
    } catch let ProviderHTTPError.rateLimited(retryAfter) {
      await rateLimitGate.recordRateLimit(
        for: credentials.accessToken,
        retryAfter: retryAfter
      )
      throw ProviderHTTPError.rateLimited(retryAfter: retryAfter)
    }
    var usage = try ClaudeUsageParser.parse(data, provider: context.provider, now: context.now)
    await rateLimitGate.recordSuccess(for: credentials.accessToken)
    if usage.plan == nil {
      usage.plan = PlanLabel.claude(
        subscriptionType: credentials.subscriptionType,
        rateLimitTier: credentials.rateLimitTier
      )
    }
    let account = ProviderAccount(
      provider: context.provider,
      displayName: "Claude Code",
      detail: nil,
      credentialSource: resolved.source,
      credentialIdentity: credentials.accessToken
    )
    return ProviderFetchResult(
      usage: usage,
      sourceLabel: "Claude",
      credentialScopeID: account.credentialScopeID,
      credentialTransitionSourceScopeIDs: credentialTransitionSourceScopeIDs
    )
  }
}
