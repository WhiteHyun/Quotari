import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAutomaticCaptureTests {
  @Test func scanAutomaticallyCapturesClaudeKeychainAccount() async throws {
    let directory = try TemporaryDirectory()
    let payload = Data(
      #"{"claudeAiOauth":{"accessToken":"claude-access","refreshToken":"claude-refresh"}}"#.utf8
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload },
      capturedAccounts: registry
    )
    let capture = AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: capture,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    await store.reloadAccounts()

    let live = try #require(store.accounts[.claude]?.first)
    let saved = try #require(registry.load().first)
    #expect(saved.provider == .claude)
    #expect(store.capturedEquivalents[live.id]?.credentialSource == .quotariRegistry(id: saved.id))
  }

  @Test func scanAutomaticallyCapturesAndAnchorsTheSelectedLiveAccount() async throws {
    let context = try makeContext(accountID: "acct-a", email: "a@example.com")
    let live = try #require(await context.discovery.accounts(for: .codex).first)
    try context.selectionStore.save([.codex: live])
    let store = context.makeStore()

    await store.reloadAccounts()

    let saved = try #require(context.registry.load().first)
    #expect(saved.id == "codex:acct-a")
    #expect(store.accounts[.codex] == [live])
    #expect(store.capturedEquivalents[live.id]?.credentialSource == .quotariRegistry(id: saved.id))
    #expect(store.selectedAccounts[.codex] == live)
    #expect(context.selectionStore.load()[.codex]?.credentialSource == .quotariRegistry(id: saved.id))
  }

  @Test func repeatedScanKeepsOneRegistryEntryAndSyncsItsLatestPayload() async throws {
    let context = try makeContext(accountID: "acct-a", email: "a@example.com")
    let store = context.makeStore()
    await store.reloadAccounts()

    try writeCodexCredentials(
      to: context.authURL,
      accountID: "acct-a",
      email: "a@example.com",
      accessToken: "access-new",
      refreshToken: "refresh-new"
    )
    await store.reloadAccounts()

    let saved = try #require(context.registry.load().first)
    let credentials = try CodexCredentialsStore.parse(saved.payload)
    #expect(context.registry.load().count == 1)
    #expect(credentials.accessToken == "access-new")
    #expect(credentials.refreshToken == "refresh-new")
  }

  @Test func oneCaptureFailureDoesNotBlockOtherDiscoveredAccounts() async throws {
    let directory = try TemporaryDirectory()
    let validURL = directory.url.appendingPathComponent("valid-auth.json")
    try writeCodexCredentials(
      to: validURL,
      accountID: "acct-valid",
      email: "valid@example.com"
    )
    let missingURL = directory.url.appendingPathComponent("missing-auth.json")
    let valid = liveCodexAccount(url: validURL, accountID: "acct-valid", email: "valid@example.com")
    let missing = liveCodexAccount(url: missingURL, accountID: "acct-missing", email: "missing@example.com")
    let registry = CapturedAccountStore.inMemoryForTesting()
    let capture = AccountCaptureService(capturedAccounts: registry)
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [valid, missing]]),
      accountCapture: capture,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(registry.load().map(\.id) == ["codex:acct-valid"])
    #expect(store.accounts[.codex] == [valid, missing])
    #expect(store.captureErrors[.codex]?.contains("missing@example.com") == true)
  }

  @Test func slotReplacementAfterCaptureKeepsTheOriginalSelection() async throws {
    let context = try makeContext(accountID: "acct-a", email: "a@example.com")
    let liveA = try #require(await context.discovery.accounts(for: .codex).first)
    try context.selectionStore.save([.codex: liveA])
    let discovery = GatedPostCaptureDiscovery(context.discovery)
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: discovery,
      accountSelectionStore: context.selectionStore,
      accountCapture: context.capture,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    let reload = Task { await store.reloadAccounts() }
    await discovery.waitUntilVerificationReadStarts()
    try writeCodexCredentials(
      to: context.authURL,
      accountID: "acct-b",
      email: "b@example.com",
      accessToken: "access-b",
      refreshToken: "refresh-b"
    )
    await discovery.resumeVerificationRead()
    await reload.value

    #expect(context.registry.load().map(\.id).sorted() == ["codex:acct-a", "codex:acct-b"])
    #expect(store.selectedAccounts[.codex]?.credentialSource == .quotariRegistry(id: "codex:acct-a"))
    #expect(context.selectionStore.load()[.codex]?.credentialSource == .quotariRegistry(id: "codex:acct-a"))
    #expect(store.capturedEquivalents.values.contains { $0.credentialSource == .quotariRegistry(id: "codex:acct-b") })
  }

  @Test func activeCLIAccountCannotBeRemoved() async throws {
    let context = try makeContext(accountID: "acct-a", email: "a@example.com")
    let store = context.makeStore()
    await store.reloadAccounts()
    let live = try #require(store.accounts[.codex]?.first)

    await store.removeCapturedCopy(of: live)

    #expect(context.registry.load().map(\.id) == ["codex:acct-a"])
    #expect(store.captureErrors[.codex] == UsageStore.activeAccountRemovalMessage)
  }

  @Test func unresolvedUnrenewableClaudeSlotBlocksSavedCopyRemoval() async throws {
    let directory = try TemporaryDirectory()
    let livePayload = Data(#"{"claudeAiOauth":{"accessToken":"shared-access"}}"#.utf8)
    let savedPayload = claudePayload(accessToken: "shared-access", refreshToken: "saved-refresh")
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Claude account",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 1),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: savedPayload
    ))
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { livePayload },
      capturedAccounts: registry
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in livePayload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [:]),
      claudeCredentialLoader: { source in
        switch source {
        case .claudeKeychain:
          try? ClaudeCredentialsStore.parse(livePayload)
        case let .quotariRegistry(id):
          registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
        case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
          nil
        }
      },
      startsAutomatically: false
    )
    await store.reloadAccounts()
    let saved = try #require(store.accounts[.claude]?.first(where: { $0.credentialSource.isCaptured }))

    await store.removeCapturedAccount(saved)

    #expect(registry.account(id: "claude:saved") != nil)
    #expect(store.captureErrors[.claude] == UsageStore.activeAccountRemovalMessage)
  }

  @Test func savedNonLiveAccountCanBeRemoved() async throws {
    let context = try makeContext(accountID: "acct-a", email: "a@example.com")
    let store = context.makeStore()
    await store.reloadAccounts()

    try writeCodexCredentials(
      to: context.authURL,
      accountID: "acct-b",
      email: "b@example.com",
      accessToken: "access-b",
      refreshToken: "refresh-b"
    )
    await store.reloadAccounts()
    let savedA = try #require(store.accounts[.codex]?.first(where: {
      $0.credentialSource == .quotariRegistry(id: "codex:acct-a")
    }))

    await store.removeCapturedAccount(savedA)

    #expect(context.registry.load().map(\.id) == ["codex:acct-b"])
    #expect(store.accounts[.codex]?.contains(where: { $0.id == savedA.id }) == false)
  }

  @Test func removalRediscoveryBlocksAnAccountSwitchedIntoTheCLISlot() async throws {
    let directory = try TemporaryDirectory()
    let authURL = directory.url.appendingPathComponent("auth.json")
    let savedPayloadURL = directory.url.appendingPathComponent("saved-auth.json")
    try writeCodexCredentials(
      to: savedPayloadURL,
      accountID: "acct-a",
      email: "a@example.com"
    )
    try writeCodexCredentials(
      to: authURL,
      accountID: "acct-b",
      email: "b@example.com"
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "codex:acct-a",
      provider: .codex,
      displayName: "a@example.com",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: authURL.path),
      payload: Data(contentsOf: savedPayloadURL)
    ))
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": directory.url.path],
      home: directory.url,
      codexKeychainData: { _, _ in nil },
      capturedAccounts: registry
    )
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      startsAutomatically: false
    )
    await store.reloadAccounts()
    let saved = try #require(store.accounts[.codex]?.first(where: { $0.credentialSource.isCaptured }))

    try writeCodexCredentials(
      to: authURL,
      accountID: "acct-a",
      email: "a@example.com"
    )
    await store.removeCapturedAccount(saved)

    #expect(registry.load().map(\.id) == ["codex:acct-a"])
    #expect(store.captureErrors[.codex] == UsageStore.activeAccountRemovalMessage)
  }
}

private func liveCodexAccount(
  url: URL,
  accountID: String,
  email: String
) -> ProviderAccount {
  ProviderAccount(
    provider: .codex,
    displayName: email,
    detail: "Default",
    credentialSource: .codexAuthFile(path: url.path),
    credentialIdentity: accountID
  )
}
