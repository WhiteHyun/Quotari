import Foundation

/// Fetches Codex usage over OAuth: reads `~/.codex/auth.json`, calls the usage
/// endpoint, and parses via the generic window mapper. Not available when no
/// credentials are present, so the pipeline can fall through.
public struct CodexUsageStrategy: ProviderFetchStrategy {
  public let id = "codex.oauth"
  public let kind: ProviderFetchKind = .oauth

  private let transport: any ProviderHTTPTransport
  private let loadCredentials: @Sendable () throws -> CodexCredentials
  private let usageURL: URL

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    usageURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
    loadCredentials: @escaping @Sendable () throws -> CodexCredentials = { try CodexCredentialsStore.load() }
  ) {
    self.transport = transport
    self.usageURL = usageURL
    self.loadCredentials = loadCredentials
  }

  public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
    if context.account != nil { return true }
    return (try? credentials(for: context)) != nil
  }

  public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let credentials = try credentials(for: context)
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
        return try CodexCredentialsStore.load(source: account.credentialSource)
      } catch {
        throw ProviderFetchError.selectedCredentialUnavailable(context.provider)
      }
    }
    return try loadCredentials()
  }
}
