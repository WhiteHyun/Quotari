import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAutomaticCaptureFallbackTests {
  @Test func failedCanonicalClaudeSourceFallsBackToRenewableDuplicate() async throws {
    let fixture = try makeFallbackFixture()

    await fixture.store.reloadAccounts()

    let saved = try #require(fixture.registry.load().first)
    let credentials = try ClaudeCredentialsStore.parse(saved.payload)
    #expect(fixture.registry.load().count == 1)
    #expect(credentials.accessToken == "file-access")
    #expect(credentials.refreshToken == "file-refresh")
    #expect(fixture.store.captureErrors[.claude] == nil)
    let live = try #require(fixture.store.accounts[.claude]?.first)
    #expect(fixture.store.accounts[.claude]?.count == 1)
    #expect(live.credentialSource == .claudeCredentialsFile(
      path: fixture.directory.url
        .appendingPathComponent(".claude/.credentials.json")
        .standardizedFileURL.path
    ))
    #expect(fixture.store.capturedEquivalents[live.id]?.credentialSource == .quotariRegistry(id: saved.id))
  }

  @Test func captureProfileResolutionReplaysDeferredClaudeNotification() async throws {
    let fixture = try await makeDeferredNotificationFixture()
    fixture.enqueueNotificationWithoutProfile()
    await fixture.store.waitForPendingQuotaNotifications()
    #expect(fixture.store.deferredClaudeQuotaNotification != nil)

    _ = await fixture.store.automaticCapturePlans(
      for: [fixture.live],
      among: [fixture.live],
      provider: .claude
    )
    await fixture.store.waitForPendingQuotaNotifications()

    #expect(fixture.store.deferredClaudeQuotaNotification == nil)
    #expect(fixture.center.attemptedRequests.map(\.kind) == [.warning])
  }
}

private struct AutomaticCaptureFallbackFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let store: UsageStore
}

@MainActor
private func makeFallbackFixture() throws -> AutomaticCaptureFallbackFixture {
  let directory = try TemporaryDirectory()
  let claudeDirectory = directory.url.appendingPathComponent(".claude", isDirectory: true)
  try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
  let fileURL = claudeDirectory.appendingPathComponent(".credentials.json")
  try claudePayload(accessToken: "file-access", refreshToken: "file-refresh").write(to: fileURL)
  let payload = AutomaticCapturePayloadBox(
    Data(#"{"claudeAiOauth":{"accessToken":"keychain-access"}}"#.utf8)
  )
  let registry = CapturedAccountStore.inMemoryForTesting()
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { payload.value },
    capturedAccounts: registry
  )
  let store = UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload.value }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: StableClaudeProfileFetcher(
      accountID: "claude-account",
      email: "claude@example.com"
    ),
    claudeCredentialLoader: { source in
      fallbackClaudeCredentials(source: source, payload: payload, registry: registry)
    },
    startsAutomatically: false
  )
  return AutomaticCaptureFallbackFixture(directory: directory, registry: registry, store: store)
}

private struct DeferredCaptureProfileFixture {
  let store: UsageStore
  let center: UsageNotificationCenterStub
  let live: ProviderAccount

  @MainActor
  func enqueueNotificationWithoutProfile() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: UsageSnapshot(
          provider: .claude,
          primary: RateWindow(
            kind: .session,
            usedPercent: 80,
            resetsAt: now.addingTimeInterval(3600)
          ),
          updatedAt: now
        ),
        sourceLabel: "Claude",
        sourceKind: .oauth,
        credentialScopeID: live.credentialScopeID
      ),
      provider: .claude,
      account: live
    )
  }
}

@MainActor
private func makeDeferredNotificationFixture() async throws -> DeferredCaptureProfileFixture {
  let directory = try TemporaryDirectory()
  let livePayload = claudePayload(accessToken: "live-access", refreshToken: "live-refresh")
  let registry = CapturedAccountStore.inMemoryForTesting()
  try registry.save(savedClaudeAccount())
  let live = liveClaudeAccount()
  let suiteName = "capture-profile-replays-notification"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  let center = UsageNotificationCenterStub()
  let controller = QuotaNotificationController(center: center, defaults: defaults)
  _ = await controller.setNotificationsEnabled(true)
  let store = makeDeferredNotificationStore(
    directory: directory,
    livePayload: livePayload,
    registry: registry,
    defaults: defaults,
    controller: controller
  )
  return DeferredCaptureProfileFixture(store: store, center: center, live: live)
}

@MainActor
private func makeDeferredNotificationStore(
  directory: TemporaryDirectory,
  livePayload: Data,
  registry: CapturedAccountStore,
  defaults: UserDefaults,
  controller: QuotaNotificationController
) -> UsageStore {
  UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in livePayload }
    ),
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "live-access": ClaudeProfile(accountID: "live-account", email: "live@example.com"),
      "saved-access": ClaudeProfile(accountID: "saved-account", email: "saved@example.com"),
    ]),
    profileStore: ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json")),
    claudeCredentialLoader: { source in
      deferredClaudeCredentials(source: source, livePayload: livePayload, registry: registry)
    },
    defaults: defaults,
    quotaNotifications: controller,
    startsAutomatically: false
  )
}

private func savedClaudeAccount() -> CapturedAccount {
  CapturedAccount(
    id: "claude:saved",
    provider: .claude,
    displayName: "Saved Claude",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeCredentialsFile(path: "/tmp/saved-claude.json"),
    payload: claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
  )
}

private func liveClaudeAccount() -> ProviderAccount {
  ProviderAccount(
    provider: .claude,
    displayName: "Claude Code",
    detail: "Keychain",
    credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    credentialIdentity: "live-access"
  )
}

private func fallbackClaudeCredentials(
  source: ProviderCredentialSource,
  payload: AutomaticCapturePayloadBox,
  registry: CapturedAccountStore
) -> ClaudeCredentials? {
  switch source {
  case .claudeKeychain:
    try? ClaudeCredentialsStore.parse(payload.value)
  case let .claudeCredentialsFile(path):
    (try? Data(contentsOf: URL(fileURLWithPath: path)))
      .flatMap { try? ClaudeCredentialsStore.parse($0) }
  case let .quotariRegistry(id):
    registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
  case .codexAuthFile, .codexKeychain, .claudeEnvironment:
    nil
  }
}

private func deferredClaudeCredentials(
  source: ProviderCredentialSource,
  livePayload: Data,
  registry: CapturedAccountStore
) -> ClaudeCredentials? {
  switch source {
  case .claudeKeychain:
    try? ClaudeCredentialsStore.parse(livePayload)
  case let .quotariRegistry(id):
    registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
  case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
    nil
  }
}
