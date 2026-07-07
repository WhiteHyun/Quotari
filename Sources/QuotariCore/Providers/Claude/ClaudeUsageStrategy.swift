import Foundation

/// Fetches Claude usage over OAuth using a token from the environment
/// (`QUOTARI_CLAUDE_OAUTH_TOKEN`). Keychain-based credential discovery is a
/// planned follow-up; until then this strategy is unavailable without the env
/// token, so the pipeline falls through cleanly.
public struct ClaudeUsageStrategy: ProviderFetchStrategy {
  public let id = "claude.oauth"
  public let kind: ProviderFetchKind = .oauth

  public static let tokenEnvKey = "QUOTARI_CLAUDE_OAUTH_TOKEN"

  private let transport: any ProviderHTTPTransport
  private let usageURL: URL
  private let token: @Sendable () -> String?

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
    token: @escaping @Sendable () -> String? = { ProcessInfo.processInfo.environment[tokenEnvKey] }
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.token = token
  }

  public func isAvailable(_: ProviderFetchContext) async -> Bool {
    token()?.isEmpty == false
  }

  public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    guard let token = token(), !token.isEmpty else {
      throw ProviderFetchError.missingCredential(context.provider)
    }
    let data = try await transport.getJSON(
      url: usageURL,
      bearer: token,
      headers: ["anthropic-beta": "oauth-2025-04-20"]
    )
    let usage = try ClaudeUsageParser.parse(data, provider: context.provider, now: context.now)
    return ProviderFetchResult(usage: usage, sourceLabel: "Claude")
  }

  public func shouldFallback(on error: Error) -> Bool {
    !(error is ProviderHTTPError)
  }
}
