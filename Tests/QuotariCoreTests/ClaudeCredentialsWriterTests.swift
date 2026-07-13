import Foundation
@testable import QuotariCore
import Testing

struct ClaudeCredentialsWriterTests {
  private static let storedPayload = """
  {
    "claudeAiOauth": {
      "accessToken": "old-tok",
      "refreshToken": "old-ref",
      "expiresAt": 1000,
      "refreshTokenExpiresAt": 99999,
      "scopes": ["user:inference"],
      "subscriptionType": "max",
      "rateLimitTier": "default_claude_max_20x"
    },
    "mcpOAuth": {
      "linear|abc": {"accessToken": "mcp-tok", "serverUrl": "https://mcp.linear.app"}
    }
  }
  """

  @Test func mergeUpdatesTokenFieldsAndPreservesEverythingElse() throws {
    let grant = ClaudeTokenGrant(
      accessToken: "new-tok",
      refreshToken: "new-ref",
      expiresAt: Date(timeIntervalSince1970: 2000),
      scopes: ["user:inference", "user:profile"]
    )

    let merged = try ClaudeCredentialsWriter()
      .merge(grant, replacing: "old-tok", into: Data(Self.storedPayload.utf8))
    let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
    let oauth = try #require(root["claudeAiOauth"] as? [String: Any])

    #expect(oauth["accessToken"] as? String == "new-tok")
    #expect(oauth["refreshToken"] as? String == "new-ref")
    #expect(oauth["expiresAt"] as? Int == 2_000_000)
    #expect(oauth["refreshTokenExpiresAt"] as? Int == 99999)
    #expect(oauth["scopes"] as? [String] == ["user:inference", "user:profile"])
    #expect(oauth["subscriptionType"] as? String == "max")
    let mcp = try #require(root["mcpOAuth"] as? [String: Any])
    #expect((mcp["linear|abc"] as? [String: Any])?["accessToken"] as? String == "mcp-tok")
  }

  @Test func mergeWithAMinimalGrantKeepsTheOldRefreshTokenAndScopes() throws {
    let grant = ClaudeTokenGrant(accessToken: "new-tok")

    let merged = try ClaudeCredentialsWriter()
      .merge(grant, replacing: "old-tok", into: Data(Self.storedPayload.utf8))
    let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
    let oauth = try #require(root["claudeAiOauth"] as? [String: Any])

    #expect(oauth["refreshToken"] as? String == "old-ref")
    #expect(oauth["scopes"] as? [String] == ["user:inference"])
    // Without a fresh expiry the stale one is dropped, matching the in-memory
    // pair (both fall back to the API's 401 as the expiry signal).
    #expect(oauth["expiresAt"] == nil)
  }

  @Test func mergeRefusesWhenTheSourceChangedSinceTheRefreshStarted() {
    let grant = ClaudeTokenGrant(accessToken: "new-tok")

    #expect(throws: ClaudeCredentialPersistError.self) {
      _ = try ClaudeCredentialsWriter()
        .merge(grant, replacing: "token-from-someone-else", into: Data(Self.storedPayload.utf8))
    }
  }

  @Test func persistsToCredentialsFileAtomicallyWithOwnerOnlyPermissions() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-credentials-\(UUID().uuidString).json")
    try Data(Self.storedPayload.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let grant = ClaudeTokenGrant(accessToken: "new-tok", refreshToken: "new-ref")

    try ClaudeCredentialsWriter()
      .persist(grant, replacing: "old-tok", to: .claudeCredentialsFile(path: url.path))

    let reloaded = try ClaudeCredentialsStore.parse(Data(contentsOf: url))
    #expect(reloaded.accessToken == "new-tok")
    #expect(reloaded.refreshToken == "new-ref")
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
  }

  @Test func permissionFailureLeavesTheCredentialFileUntouchedAndCleansTheTemporaryFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(".credentials.json")
    let original = Data(Self.storedPayload.utf8)
    try original.write(to: url)
    let writer = ClaudeCredentialsWriter(
      setOwnerOnlyPermissions: { _ in throw WriterPermissionError() }
    )

    #expect(throws: WriterPermissionError.self) {
      try writer.persist(
        ClaudeTokenGrant(accessToken: "new-tok"),
        replacing: "old-tok",
        to: .claudeCredentialsFile(path: url.path)
      )
    }

    #expect(try Data(contentsOf: url) == original)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix(".credentials.json.quotari.") }
    #expect(leftovers.isEmpty)
  }

  @Test func persistsToKeychainThroughInjectedSeam() throws {
    final class Box: @unchecked Sendable { var written: (data: Data, service: String)? }
    let box = Box()
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in Data(Self.storedPayload.utf8) },
      keychainWrite: { box.written = ($0, $1) }
    )
    let grant = ClaudeTokenGrant(accessToken: "new-tok")

    try writer.persist(grant, replacing: "old-tok", to: .claudeKeychain(service: "Custom-Service"))

    let written = try #require(box.written)
    #expect(written.service == "Custom-Service")
    #expect(try ClaudeCredentialsStore.parse(written.data).accessToken == "new-tok")
  }

  @Test func environmentSourceIsANoOp() throws {
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in Issue.record("must not write") }
    )
    try writer.persist(
      ClaudeTokenGrant(accessToken: "new-tok"),
      replacing: "old-tok",
      to: .claudeEnvironment(name: "QUOTARI_CLAUDE_OAUTH_TOKEN")
    )
  }
}

private struct WriterPermissionError: Error {}

struct ClaudeStrategyRefreshTests {
  private static let now = Date(timeIntervalSince1970: 1_767_744_000)

  private static func expiredCredentials() -> ClaudeCredentials {
    ClaudeCredentials(
      accessToken: "expired-tok",
      refreshToken: "old-ref",
      expiresAt: now.addingTimeInterval(-10)
    )
  }

  private static func missingFileSource() -> ProviderCredentialSource {
    .claudeCredentialsFile(path: "/missing/\(UUID().uuidString).json")
  }

  private static func strategy(
    transport: RefreshStubTransport,
    source: ProviderCredentialSource,
    credentials: ClaudeCredentials,
    refresher: StubRefresher,
    persister: RecordingPersister
  ) -> ClaudeUsageStrategy {
    ClaudeUsageStrategy(
      transport: transport,
      resolveCredentials: {
        ResolvedClaudeCredentials(credentials: credentials, source: source)
      },
      refresher: refresher,
      persister: persister,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )
  }

  @Test func expiredTokenIsRefreshedPersistedAndUsed() async throws {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "fresh-tok",
      refreshToken: "fresh-ref",
      expiresAt: Self.now.addingTimeInterval(3600)
    )))
    let persister = RecordingPersister()
    let source = Self.missingFileSource()
    let strategy = Self.strategy(
      transport: transport,
      source: source,
      credentials: Self.expiredCredentials(),
      refresher: refresher,
      persister: persister
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-tok")
    #expect(persister.persisted.map(\.grant.accessToken) == ["fresh-tok"])
    #expect(persister.persisted.first?.previousAccessToken == "expired-tok")
    #expect(persister.persisted.first?.source == source)
  }

  @Test func freshTokenSkipsTheRefresher() async throws {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let refresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse))
    let strategy = Self.strategy(
      transport: transport,
      source: Self.missingFileSource(),
      credentials: ClaudeCredentials(
        accessToken: "live-tok",
        refreshToken: "ref",
        expiresAt: Self.now.addingTimeInterval(3600)
      ),
      refresher: refresher,
      persister: RecordingPersister()
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    #expect(refresher.calls.isEmpty)
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-tok")
  }

  @Test func sourceAlreadyHoldingAFreshPairShortCircuitsTheRefresher() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-already-fresh-\(UUID().uuidString).json")
    try Self.credentialsJSON(token: "already-fresh-tok").write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let refresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse))
    let strategy = Self.strategy(
      transport: transport,
      source: .claudeCredentialsFile(path: url.path),
      credentials: Self.expiredCredentials(),
      refresher: refresher,
      persister: RecordingPersister()
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    #expect(refresher.calls.isEmpty)
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer already-fresh-tok")
  }

  @Test func failedRefreshFallsBackToRereadingTheSource() async throws {
    // The file starts with the same expired pair; Claude Code rotates it
    // mid-refresh, which is why our refresh fails.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-refreshed-\(UUID().uuidString).json")
    try Self.credentialsJSON(token: "expired-tok", expiresIn: -10).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let refresher = StubRefresher(
      result: .failure(ProviderHTTPError.unauthorized),
      onRefresh: { try? Self.credentialsJSON(token: "cc-rotated-tok").write(to: url) }
    )
    let strategy = Self.strategy(
      transport: transport,
      source: .claudeCredentialsFile(path: url.path),
      credentials: Self.expiredCredentials(),
      refresher: refresher,
      persister: RecordingPersister()
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    #expect(refresher.calls == ["old-ref"])
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cc-rotated-tok")
  }

  @Test func failedRefreshWithoutBetterCredentialsKeepsTheOldToken() async throws {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let strategy = Self.strategy(
      transport: transport,
      source: Self.missingFileSource(),
      credentials: Self.expiredCredentials(),
      refresher: StubRefresher(result: .failure(ProviderHTTPError.unauthorized)),
      persister: RecordingPersister()
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-tok")
  }

  @Test func staleSourceDuringPersistPrefersTheSourcePair() async throws {
    // A re-login lands while our refresh POST is in flight; the persist's
    // stale-source guard fires and the re-login's pair wins.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-relogin-\(UUID().uuidString).json")
    try Self.credentialsJSON(token: "expired-tok", expiresIn: -10).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let persister = RecordingPersister(error: ClaudeCredentialPersistError.staleSource)
    let refresher = StubRefresher(
      result: .success(ClaudeTokenGrant(accessToken: "fresh-tok")),
      onRefresh: { try? Self.credentialsJSON(token: "relogin-tok").write(to: url) }
    )
    let strategy = Self.strategy(
      transport: transport,
      source: .claudeCredentialsFile(path: url.path),
      credentials: Self.expiredCredentials(),
      refresher: refresher,
      persister: persister
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer relogin-tok")
  }

  @Test func otherPersistFailuresStillUseTheRefreshedToken() async throws {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let persister = RecordingPersister(error: ClaudeCredentialPersistError.keychainWriteFailed(status: 1))
    let strategy = Self.strategy(
      transport: transport,
      source: Self.missingFileSource(),
      credentials: Self.expiredCredentials(),
      refresher: StubRefresher(result: .success(ClaudeTokenGrant(accessToken: "fresh-tok"))),
      persister: persister
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-tok")
  }

  @Test func concurrentFetchesShareOneRefreshAndPersist() async {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: "{}", recorder: recorder)
    let refresher = StubRefresher(
      result: .success(ClaudeTokenGrant(accessToken: "fresh-tok")),
      delay: .milliseconds(100)
    )
    let persister = RecordingPersister()
    let strategy = Self.strategy(
      transport: transport,
      source: Self.missingFileSource(),
      credentials: Self.expiredCredentials(),
      refresher: refresher,
      persister: persister
    )
    let context = ProviderFetchContext(provider: .claude, now: Self.now)

    async let first = strategy.fetch(context)
    async let second = strategy.fetch(context)
    _ = try? await first
    _ = try? await second

    // One transaction total: the rotating refresh token is spent once and
    // persisted once, and both fetches proceed with the same fresh pair.
    #expect(refresher.calls == ["old-ref"])
    #expect(persister.persisted.count == 1)
    #expect(recorder.requests.count == 2)
    #expect(recorder.requests.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-tok"
    })
  }

  private static func credentialsJSON(token: String, expiresIn: TimeInterval = 3600) -> Data {
    Data("""
    {
      "claudeAiOauth": {
        "accessToken": "\(token)",
        "refreshToken": "some-ref",
        "expiresAt": \(Int((now.timeIntervalSince1970 + expiresIn) * 1000))
      }
    }
    """.utf8)
  }
}
