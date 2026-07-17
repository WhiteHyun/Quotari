import Foundation
@testable import QuotariCore
import Testing

struct ProviderAccountDiscoveryTests {
  @Test func discoversCodexDefaultAndCodexHomeAccounts() async throws {
    let home = try TemporaryDirectory()
    let codexDir = home.url.appendingPathComponent(".codex", isDirectory: true)
    let customCodexHome = home.url.appendingPathComponent("custom-codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: customCodexHome, withIntermediateDirectories: true)
    try Self.writeCodexAuth(
      to: codexDir.appendingPathComponent("auth.json"),
      token: "default-token",
      accountID: "default-account"
    )
    try Self.writeCodexAuth(
      to: customCodexHome.appendingPathComponent("auth.json"),
      token: "custom-token",
      accountID: "custom-account"
    )

    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": customCodexHome.path],
      home: home.url,
      keychainData: { nil },
      capturedAccounts: CapturedAccountStore(
        keychain: InMemoryKeychain().store,
        service: "Discovery-Codex-\(UUID().uuidString)"
      )
    )

    let accounts = await discovery.accounts(for: .codex)

    #expect(accounts.map(\.displayName) == ["default-account", "custom-account"])
    #expect(accounts.map(\.detail) == ["Default", "CODEX_HOME"])
    #expect(accounts.allSatisfy { $0.provider == .codex })
  }

  @Test func discoversClaudeEnvironmentKeychainAndFileAccounts() async throws {
    let home = try TemporaryDirectory()
    let claudeDir = home.url.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    let fileURL = claudeDir.appendingPathComponent(".credentials.json")
    let fileData = Self.claudeCredentials(token: "file-token", tier: "default_claude_max_20x")
    try fileData.write(to: fileURL)
    let keychainData = Self.claudeCredentials(token: "keychain-token", tier: "default_claude_max_5x")

    let discovery = ProviderAccountDiscovery(
      environment: [ClaudeCredentialsStore.tokenEnvKey: "env-token"],
      home: home.url,
      keychainData: { keychainData },
      capturedAccounts: CapturedAccountStore(
        keychain: InMemoryKeychain().store,
        service: "Discovery-Claude-\(UUID().uuidString)"
      )
    )

    let accounts = await discovery.accounts(for: .claude)

    #expect(accounts.map(\.detail) == [
      ClaudeCredentialsStore.tokenEnvKey, "Keychain", "Credentials file",
    ])
    #expect(accounts.map(\.displayName) == [
      "Claude OAuth token", "Claude Code", "Claude Code",
    ])
    #expect(accounts.allSatisfy { $0.provider == .claude })
  }

  fileprivate static func writeCodexAuth(to url: URL, token: String, accountID: String) throws {
    try Data(#"{ "tokens": { "access_token": "\#(token)", "account_id": "\#(accountID)" } }"#.utf8)
      .write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  fileprivate static func claudeCredentials(token: String, tier: String) -> Data {
    Data("""
    {
      "claudeAiOauth": {
        "accessToken": "\(token)",
        "subscriptionType": "max",
        "rateLimitTier": "\(tier)"
      }
    }
    """.utf8)
  }
}

struct ProviderAccountSelectionStoreTests {
  @Test func roundTripsSelectedAccounts() throws {
    let directory = try TemporaryDirectory()
    let store = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let account = ProviderAccount(
      provider: .codex,
      displayName: "dev@example.com",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )

    try store.save([.codex: account])

    #expect(store.load() == [.codex: account])
  }
}

struct ProviderAccountMonitoringStoreTests {
  @Test func roundTripsMultipleAndExplicitlyEmptyProviderSelections() throws {
    let directory = try TemporaryDirectory()
    let store = ProviderAccountMonitoringStore(
      url: directory.url.appendingPathComponent("MonitoredProviderAccounts.json")
    )
    let personal = ProviderAccount(
      provider: .codex,
      displayName: "Personal",
      detail: "Default",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let work = ProviderAccount(
      provider: .codex,
      displayName: "Work",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:work")
    )

    try store.save([.codex: [personal, work], .claude: []])

    #expect(try store.load() == [.codex: [personal, work], .claude: []])
  }

  @Test func malformedConfigurationDoesNotLookLikeFirstLaunch() throws {
    let directory = try TemporaryDirectory()
    let url = directory.url.appendingPathComponent("MonitoredProviderAccounts.json")
    try Data("not-json".utf8).write(to: url)
    let store = ProviderAccountMonitoringStore(url: url)

    #expect(throws: (any Error).self) {
      try store.load()
    }
  }

  @Test func duplicateProviderConfigurationThrowsInsteadOfTrapping() throws {
    let directory = try TemporaryDirectory()
    let url = directory.url.appendingPathComponent("MonitoredProviderAccounts.json")
    try Data(#"{"selections":[{"provider":"codex","accounts":[]},{"provider":"codex","accounts":[]}]}"#.utf8)
      .write(to: url)
    let store = ProviderAccountMonitoringStore(url: url)

    #expect(throws: DecodingError.self) {
      try store.load()
    }
  }
}

struct ProviderAccountStrategyTests {
  @Test func codexStrategyUsesSelectedAccountSource() async throws {
    let directory = try TemporaryDirectory()
    let selectedURL = directory.url.appendingPathComponent("selected-auth.json")
    try ProviderAccountDiscoveryTests.writeCodexAuth(
      to: selectedURL,
      token: "selected-token",
      accountID: "selected-account"
    )
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Selected",
      detail: "Test",
      credentialSource: .codexAuthFile(path: selectedURL.path)
    )
    let recorder = StubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: StubTransport(json: Self.codexUsageJSON, recorder: recorder),
      loadCredentials: { CodexCredentials(accessToken: "default-token", accountID: "default-account") }
    )

    _ = try await strategy.fetch(ProviderFetchContext(provider: .codex, now: Date(), account: account))

    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-token")
    #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "selected-account")
  }

  @Test func claudeStrategyUsesSelectedAccountSource() async throws {
    let directory = try TemporaryDirectory()
    let selectedURL = directory.url.appendingPathComponent("selected-credentials.json")
    try ProviderAccountDiscoveryTests
      .claudeCredentials(token: "selected-token", tier: "default_claude_max_20x")
      .write(to: selectedURL)
    let account = ProviderAccount(
      provider: .claude,
      displayName: "Selected",
      detail: "Test",
      credentialSource: .claudeCredentialsFile(path: selectedURL.path)
    )
    let recorder = StubTransport.Recorder()
    let strategy = ClaudeUsageStrategy(
      transport: StubTransport(json: Self.claudeUsageJSON, recorder: recorder),
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(
            accessToken: "default-token",
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_5x"
          ),
          source: .claudeEnvironment(name: "QUOTARI_TEST")
        )
      }
    )

    let result = try await strategy.fetch(
      ProviderFetchContext(provider: .claude, now: Date(), account: account)
    )

    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-token")
    #expect(result.usage.plan == "Max 20x")
  }

  @Test func missingSelectedCodexCredentialDoesNotFallBackToMock() async {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Missing",
      detail: "Test",
      credentialSource: .codexAuthFile(path: "/missing/codex/auth.json")
    )
    let live = CodexUsageStrategy(
      transport: StubTransport(json: Self.codexUsageJSON),
      loadCredentials: { CodexCredentials(accessToken: "default-token", accountID: "default-account") }
    )
    let pipeline = ProviderFetchPipeline { _ in [live, MockProviders.codexStrategy] }

    do {
      _ = try await pipeline.fetch(
        ProviderFetchContext(provider: .codex, now: Date(), account: account)
      ).get()
      Issue.record("Expected the selected Codex credential to fail")
    } catch let ProviderFetchError.selectedCredentialUnavailable(provider) {
      #expect(provider == .codex)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func missingSelectedClaudeCredentialDoesNotFallBackToMock() async {
    let account = ProviderAccount(
      provider: .claude,
      displayName: "Missing",
      detail: "Test",
      credentialSource: .claudeCredentialsFile(path: "/missing/claude/.credentials.json")
    )
    let live = ClaudeUsageStrategy(
      transport: StubTransport(json: Self.claudeUsageJSON),
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(accessToken: "default-token"),
          source: .claudeEnvironment(name: "QUOTARI_TEST")
        )
      }
    )
    let pipeline = ProviderFetchPipeline { _ in [live, MockProviders.claudeStrategy] }

    do {
      _ = try await pipeline.fetch(
        ProviderFetchContext(provider: .claude, now: Date(), account: account)
      ).get()
      Issue.record("Expected the selected Claude credential to fail")
    } catch let ProviderFetchError.selectedCredentialUnavailable(provider) {
      #expect(provider == .claude)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private static let codexUsageJSON = """
  {
    "rate_limit": {
      "primary_window": { "used_percent": 10, "reset_at": 1767744000, "limit_window_seconds": 18000 }
    }
  }
  """

  private static let claudeUsageJSON = """
  {
    "five_hour": { "utilization": 32, "resets_at": "2026-01-07T00:00:00.573174+00:00" }
  }
  """
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-account-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

private struct StubTransport: ProviderHTTPTransport {
  let body: Data
  let status: Int
  let recorder: Recorder?

  final class Recorder: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) {
      requests.append(request)
    }
  }

  init(json: String, status: Int = 200, recorder: Recorder? = nil) {
    body = Data(json.utf8)
    self.status = status
    self.recorder = recorder
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorder?.record(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: nil
    )!
    return (body, response)
  }
}
