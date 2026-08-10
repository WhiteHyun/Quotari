import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAutomaticCaptureLatencyTests {
  @Test func soleClaudeAccountWaitsForVerifiedIdentityBeforeItIsManaged() async throws {
    let directory = try TemporaryDirectory()
    let payload = claudePayload(accessToken: "claude-access", refreshToken: "claude-refresh")
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload },
      capturedAccounts: registry
    )
    let profileFetcher = GatedAutomaticCaptureProfileFetcher()
    let completion = AutomaticCaptureCompletion()
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in payload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: profileFetcher,
      claudeCredentialLoader: { source in
        claudeCredentials(source: source, payload: payload, registry: registry)
      },
      startsAutomatically: false
    )

    let reload = Task {
      await store.reloadAccounts()
      await completion.markFinished()
    }
    await profileFetcher.waitUntilRequestStarts()

    #expect(await !completion.isFinished)
    #expect(registry.load().isEmpty)

    await profileFetcher.resume()
    await reload.value
    let captured = try #require(registry.load().first)
    #expect(await completion.isFinished)
    #expect(captured.claudeAccountIdentity == ClaudeAccountIdentity(
      accountID: "claude-account",
      email: "claude@example.com",
      organizationID: "claude-organization"
    ))
  }

  private nonisolated func claudeCredentials(
    source: ProviderCredentialSource,
    payload: Data,
    registry: CapturedAccountStore
  ) -> ClaudeCredentials? {
    switch source {
    case .claudeKeychain:
      try? ClaudeCredentialsStore.parse(payload)
    case let .quotariRegistry(id):
      registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
    case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
      nil
    }
  }
}

private actor AutomaticCaptureCompletion {
  private(set) var isFinished = false

  func markFinished() {
    isFinished = true
  }
}

private actor GatedAutomaticCaptureProfileFetcher: ClaudeProfileFetching {
  private var requestStarted = false
  private var isReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    requestStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    if !isReleased {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return ClaudeProfile(
      accountID: "claude-account",
      email: "claude@example.com",
      organizationID: "claude-organization"
    )
  }

  func waitUntilRequestStarts() async {
    guard !requestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resume() {
    isReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
