import Foundation

/// Fetches Claude usage over OAuth using credentials discovered from the
/// environment, the Claude Code keychain item, or `~/.claude/.credentials.json`.
/// Not available when no credentials are found, so the pipeline falls through.
public struct ClaudeUsageStrategy: ProviderFetchStrategy {
  public let id = "claude.oauth"
  public let kind: ProviderFetchKind = .oauth

  private let transport: any ProviderHTTPTransport
  private let usageURL: URL
  private let loadCredentials: @Sendable () throws -> ClaudeCredentials

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
    loadCredentials: @escaping @Sendable () throws -> ClaudeCredentials = { try ClaudeCredentialsStore.load() }
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.loadCredentials = loadCredentials
  }

  public func isAvailable(_: ProviderFetchContext) async -> Bool {
    (try? loadCredentials()) != nil
  }

  public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let credentials = try loadCredentials()
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
    !(error is ProviderHTTPError)
  }
}
