import Foundation
@testable import QuotariCore
import Testing

struct CodexAutomaticCredentialTests {
  @Test func automaticFetchUsesDefaultCredentialAndScope() async throws {
    let home = try CodexAutomaticTemporaryDirectory()
    let authURL = CodexCredentialsStore.defaultURL(home: home.url)
    try writeAuth(to: authURL, token: "default-token", accountID: "default-account")
    let recorder = RequestRecorder()
    let strategy = CodexUsageStrategy(
      transport: AutomaticCredentialTransport(recorder: recorder),
      environment: [:],
      home: home.url
    )

    let result = try await strategy.fetch(context)

    #expect(recorder.authorization == "Bearer default-token")
    #expect(result.credentialScopeID == account(
      path: authURL.standardizedFileURL.path,
      accountID: "default-account"
    ).credentialScopeID)
  }

  @Test func automaticFetchPrefersCodexHomeAndMatchesDiscoveryScope() async throws {
    let home = try CodexAutomaticTemporaryDirectory()
    let codexHome = home.url.appendingPathComponent("custom-codex", isDirectory: true)
    let authURL = codexHome.appendingPathComponent("auth.json")
    try writeAuth(to: authURL, token: "home-token", accountID: "home-account")
    let environment = ["CODEX_HOME": codexHome.path]
    let recorder = RequestRecorder()
    let strategy = CodexUsageStrategy(
      transport: AutomaticCredentialTransport(recorder: recorder),
      environment: environment,
      home: home.url
    )
    let pipeline = ProviderFetchPipeline { _ in [strategy, MockProviders.codexStrategy] }

    let result = try await pipeline.fetch(context).get()
    let accounts = await ProviderAccountDiscovery(
      environment: environment,
      home: home.url,
      keychainData: { nil }
    ).accounts(for: .codex)
    let discovered = try #require(accounts.first)

    #expect(result.sourceLabel == "Codex")
    #expect(recorder.authorization == "Bearer home-token")
    #expect(
      discovered.credentialSource
        == ProviderCredentialSource.codexAuthFile(path: authURL.standardizedFileURL.path)
    )
    #expect(result.credentialScopeID == discovered.credentialScopeID)
  }

  @Test func activeCLIAccountUsesCodexHomeInsteadOfTheFirstDiscoveredRow() async throws {
    let home = try CodexAutomaticTemporaryDirectory()
    let defaultURL = CodexCredentialsStore.defaultURL(home: home.url)
    try writeAuth(to: defaultURL, token: "default-token", accountID: "default-account")
    let codexHome = home.url.appendingPathComponent("custom-codex", isDirectory: true)
    let codexHomeURL = codexHome.appendingPathComponent("auth.json")
    try writeAuth(to: codexHomeURL, token: "home-token", accountID: "home-account")
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": codexHome.path],
      home: home.url,
      keychainData: { nil }
    )

    let accounts = await discovery.accounts(for: .codex)
    let active = await discovery.activeCLIAccount(for: .codex, among: accounts)

    #expect(accounts.first?.credentialSource == .codexAuthFile(path: defaultURL.standardizedFileURL.path))
    #expect(active?.credentialSource == .codexAuthFile(path: codexHomeURL.standardizedFileURL.path))
  }

  @Test func automaticFetchUsesTheConfiguredKeyringAndMatchesDiscoveryScope() async throws {
    let home = try CodexAutomaticTemporaryDirectory()
    let codexHome = home.url.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try Data("cli_auth_credentials_store = \"keyring\"\n".utf8)
      .write(to: codexHome.appendingPathComponent("config.toml"))
    let payload = Data(#"""
    {"tokens":{
      "id_token":"e30.e30.sig",
      "access_token":"keyring-token",
      "account_id":"keyring-account",
      "refresh_token":"keyring-refresh"
    }}
    """#.utf8)
    let recorder = RequestRecorder()
    let read: @Sendable (String, String) throws -> Data? = { _, _ in payload }
    let strategy = CodexUsageStrategy(
      transport: AutomaticCredentialTransport(recorder: recorder),
      environment: [:],
      home: home.url,
      codexKeychainRead: read
    )
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: home.url,
      keychainData: { nil },
      codexKeychainData: { _, _ in payload }
    )

    let result = try await strategy.fetch(context)
    let discovered = try #require(await discovery.accounts(for: .codex).first)

    #expect(recorder.authorization == "Bearer keyring-token")
    #expect(discovered.credentialSource == CodexAuthStorage(
      environment: [:],
      home: home.url,
      keychainRead: read
    ).keychainSource)
    #expect(result.credentialScopeID == discovered.credentialScopeID)
  }

  @Test func codexHomeMatchingDefaultProducesOneEffectiveAccount() async throws {
    let home = try CodexAutomaticTemporaryDirectory()
    let codexHome = home.url.appendingPathComponent(".codex", isDirectory: true)
    let authURL = codexHome.appendingPathComponent("auth.json")
    try writeAuth(to: authURL, token: "shared-token", accountID: "shared-account")
    let environment = ["CODEX_HOME": codexHome.path]

    let accounts = await ProviderAccountDiscovery(
      environment: environment,
      home: home.url,
      keychainData: { nil }
    ).accounts(for: .codex)

    #expect(accounts.count == 1)
    #expect(
      accounts.first?.credentialSource
        == ProviderCredentialSource.codexAuthFile(path: authURL.standardizedFileURL.path)
    )
  }

  @Test func invalidCodexHomeDoesNotSilentlyUseDefaultCredential() async throws {
    let home = try CodexAutomaticTemporaryDirectory()
    try writeAuth(
      to: CodexCredentialsStore.defaultURL(home: home.url),
      token: "default-token",
      accountID: "default-account"
    )
    let codexHome = home.url.appendingPathComponent("custom-codex", isDirectory: true)
    let invalidURL = codexHome.appendingPathComponent("auth.json")
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try Data(#"{"tokens":{}}"#.utf8).write(to: invalidURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalidURL.path)
    let strategy = CodexUsageStrategy(
      transport: AutomaticCredentialTransport(recorder: RequestRecorder()),
      environment: ["CODEX_HOME": codexHome.path],
      home: home.url
    )
    let pipeline = ProviderFetchPipeline { _ in [strategy, MockProviders.codexStrategy] }

    let result = try await pipeline.fetch(context).get()

    #expect(result.sourceLabel == "Mock")
  }

  private var context: ProviderFetchContext {
    ProviderFetchContext(provider: .codex, now: Date(timeIntervalSince1970: 1_767_744_000))
  }

  private func account(path: String, accountID: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: accountID,
      detail: nil,
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: accountID
    )
  }

  private func writeAuth(to url: URL, token: String, accountID: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#.utf8)
      .write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

private final class RequestRecorder: @unchecked Sendable {
  private(set) var authorization: String?

  func record(_ request: URLRequest) {
    authorization = request.value(forHTTPHeaderField: "Authorization")
  }
}

private struct AutomaticCredentialTransport: ProviderHTTPTransport {
  let recorder: RequestRecorder

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorder.record(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    return (Self.usageJSON, response)
  }

  private static let usageJSON = Data(#"""
  {
    "plan_type":"pro",
    "rate_limit":{
      "primary_window":{
        "used_percent":10,
        "reset_at":1767744000,
        "limit_window_seconds":18000
      }
    }
  }
  """#.utf8)
}

private final class CodexAutomaticTemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
