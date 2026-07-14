import Foundation
@testable import QuotariCore
import Testing

struct ClaudeAcceptedGrantCacheTests {
  private static let now = Date(timeIntervalSince1970: 1_767_744_000)

  @Test func staleSourceWithReusedAccessDoesNotCacheAnotherRefreshPair() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-reused-access-\(UUID().uuidString).json")
    try Self.credentialsJSON(
      accessToken: "expired-tok",
      refreshToken: "old-ref",
      expiresIn: -10
    ).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = ProviderCredentialSource.claudeCredentialsFile(path: url.path)
    let coordinator = ClaudeTokenRefreshCoordinator()
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: "{}"),
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(
            accessToken: "expired-tok",
            refreshToken: "old-ref",
            expiresAt: Self.now.addingTimeInterval(-10)
          ),
          source: source
        )
      },
      refresher: StubRefresher(
        result: .success(ClaudeTokenGrant(accessToken: "fresh-tok", refreshToken: "fresh-ref")),
        onRefresh: {
          try? Self.credentialsJSON(accessToken: "fresh-tok", refreshToken: "other-ref").write(to: url)
        }
      ),
      persister: RecordingPersister(error: ClaudeCredentialPersistError.staleSource),
      refreshCoordinator: coordinator
    )

    _ = try? await strategy.fetch(ProviderFetchContext(provider: .claude, now: Self.now))

    #expect(
      await coordinator.acceptedGrant(
        sourceID: source.stableID,
        accessToken: "fresh-tok",
        refreshToken: "other-ref"
      ) == nil
    )
  }

  private static func credentialsJSON(
    accessToken: String,
    refreshToken: String,
    expiresIn: TimeInterval = 3600
  ) -> Data {
    Data("""
    {
      "claudeAiOauth": {
        "accessToken": "\(accessToken)",
        "refreshToken": "\(refreshToken)",
        "expiresAt": \(Int((now.timeIntervalSince1970 + expiresIn) * 1000))
      }
    }
    """.utf8)
  }
}
