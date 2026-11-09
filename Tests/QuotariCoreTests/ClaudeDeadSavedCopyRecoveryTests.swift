import Foundation
@testable import QuotariCore
import Testing

/// A saved copy must never be left holding a refresh token that Quotari itself
/// consumed on the live CLI slot's behalf, and a token the server already
/// rejected must not be resubmitted on every refresh cycle.
struct ClaudeDeadSavedCopyRecoveryTests {
  private static let liveSource = ProviderCredentialSource.claudeKeychain(service: "Test-Live-Claude")
  private static let savedAccount = ProviderAccount(
    provider: .claude,
    displayName: "Saved Claude",
    detail: nil,
    credentialSource: .quotariRegistry(id: "claude:fp-1")
  )
  private static let issuedGrant = ClaudeTokenGrant(
    accessToken: "token-b",
    refreshToken: "ref-b",
    expiresAt: Date(timeIntervalSince1970: 100_000)
  )

  @Test func aFailedLiveWriteStillHandsTheIssuedGrantToTheLinkedSavedCopy() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000)
    )
    let live = KeychainSlot(claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000))
    let refresher = StubRefresher(result: .success(Self.issuedGrant))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: {
        try ResolvedClaudeCredentials(
          credentials: ClaudeCredentialsStore.parse(#require(live.value)),
          source: Self.liveSource
        )
      },
      refresher: refresher,
      // The CLI slot is unwritable, as a locked keychain is during sleep.
      persister: RecordingPersister(error: ClaudeCredentialPersistError.keychainWriteFailed(status: 1)),
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      liveSuccessorSources: []
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      capturedRegistryID: "claude:fp-1"
    ))

    #expect(refresher.calls == ["ref-a"])
    let saved = try ClaudeCredentialsStore.load(source: Self.savedAccount.credentialSource, capturedAccounts: store)
    #expect(saved.accessToken == "token-b")
    #expect(saved.refreshToken == "ref-b")
    #expect(store.pendingGrantData(id: "claude:fp-1") == nil)
  }

  @Test func aDeadSavedCopyAdoptsTheGrantIssuedForItsLiveSlot() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000)
    )
    let livePending = ClaudePendingGrant(
      grant: Self.issuedGrant,
      previousAccessToken: "token-a",
      consumedRefreshToken: "ref-a"
    )
    let liveID = try #require(Self.liveSource.claudeLivePendingGrantID)
    try store.saveLivePendingGrantIfAbsent(JSONEncoder().encode(livePending), id: liveID)
    let refresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.reauthenticationRequired))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      refresher: refresher,
      persister: RecordingPersister(),
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      liveSuccessorSources: [Self.liveSource]
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      account: Self.savedAccount
    ))

    // The consumed token is never submitted; lineage alone recovers the copy.
    #expect(refresher.calls.isEmpty)
    let saved = try ClaudeCredentialsStore.load(source: Self.savedAccount.credentialSource, capturedAccounts: store)
    #expect(saved.accessToken == "token-b")
    // The live slot still needs its own recovery record.
    #expect(store.pendingGrantData(id: liveID) != nil)
  }

  @Test func anUnrelatedLiveGrantIsNotAdopted() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000)
    )
    let otherLogin = ClaudePendingGrant(
      grant: Self.issuedGrant,
      previousAccessToken: "token-x",
      consumedRefreshToken: "ref-x"
    )
    let liveID = try #require(Self.liveSource.claudeLivePendingGrantID)
    try store.saveLivePendingGrantIfAbsent(JSONEncoder().encode(otherLogin), id: liveID)
    let refresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.reauthenticationRequired))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      refresher: refresher,
      persister: RecordingPersister(),
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      liveSuccessorSources: [Self.liveSource]
    )

    await #expect(throws: ClaudeTokenRefreshError.self) {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: Date(timeIntervalSince1970: 2000),
        account: Self.savedAccount
      ))
    }
    #expect(refresher.calls == ["ref-a"])
    let saved = try ClaudeCredentialsStore.load(source: Self.savedAccount.credentialSource, capturedAccounts: store)
    #expect(saved.accessToken == "token-a")
  }

  @Test func aRejectedRefreshTokenIsNotResubmittedEveryCycle() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000)
    )
    let refresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.reauthenticationRequired))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      refresher: refresher,
      persister: RecordingPersister(),
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      liveSuccessorSources: []
    )
    let context = ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      account: Self.savedAccount
    )

    for _ in 0 ..< 3 {
      await #expect(throws: ClaudeTokenRefreshError.self) {
        _ = try await strategy.fetch(context)
      }
    }
    #expect(refresher.calls == ["ref-a"])

    // A new generation (relogin, external rotation) is exchanged again.
    try store.updatePayload(id: "claude:fp-1") { _ in
      claudePayload(accessToken: "token-c", refreshToken: "ref-c", expiresAt: 1000)
    }
    await #expect(throws: ClaudeTokenRefreshError.self) {
      _ = try await strategy.fetch(context)
    }
    #expect(refresher.calls == ["ref-a", "ref-c"])
  }
}
