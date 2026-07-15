import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAutomaticCaptureRaceTests {
  @Test func replacedSelectedSlotIsNotAnchoredToTheNewlyCapturedAccount() async throws {
    let directory = try TemporaryDirectory()
    let codexDirectory = directory.url.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let authURL = codexDirectory.appendingPathComponent("auth.json")
    try writeRaceCodexCredentials(
      to: authURL,
      accountID: "account-a",
      email: "a@example.com"
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let baseDiscovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { nil },
      codexKeychainData: { _, _ in nil },
      capturedAccounts: registry
    )
    let selected = try #require(await baseDiscovery.accounts(for: .codex).first)
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("selection.json")
    )
    try selectionStore.save([.codex: selected])
    let discovery = ReplacingCodexDiscovery(
      base: baseDiscovery,
      authURL: authURL,
      replacementAccountID: "account-b",
      replacementEmail: "b@example.com"
    )
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    await store.reloadAccounts()

    let live = try #require(store.accounts[.codex]?.first)
    #expect(live.credentialScopeID != selected.credentialScopeID)
    #expect(registry.load().map(\.id) == ["codex:account-b"])
    #expect(store.selectedAccounts[.codex] == nil)
    #expect(selectionStore.load()[.codex] == nil)
  }

  @Test func replacedSlotCannotOverwriteOrAnchorAnExistingSavedAccount() async throws {
    let fixture = try await makeExistingSavedReplacementFixture()

    await fixture.store.reloadAccounts()

    let saved = try #require(fixture.registry.account(id: "codex:account-b"))
    #expect(try CodexCredentialsStore.parse(saved.payload).accessToken == fixture.freshAccessToken)
    #expect(fixture.store.selectedAccounts[.codex] == nil)
    #expect(fixture.selectionStore.load()[.codex] == nil)
  }

  @Test func duplicateSuppressionDoesNotHideAReplacementObservedAfterCapture() async throws {
    let fixture = try makeClaudeDuplicateReplacementFixture()

    let reload = Task { await fixture.store.reloadAccounts() }
    await fixture.discovery.waitUntilVerificationReadStarts()
    try claudePayload(
      accessToken: "replacement-access",
      refreshToken: "replacement-refresh"
    ).write(to: fixture.fileURL)
    await fixture.discovery.resumeVerificationRead()
    await reload.value

    let fileAccount = fixture.store.accounts[.claude]?.first {
      if case .claudeCredentialsFile = $0.credentialSource {
        return true
      }
      return false
    }
    #expect(fixture.registry.load().count == 2)
    #expect(fileAccount?.credentialScopeID == ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: nil,
      credentialSource: .claudeCredentialsFile(path: fixture.fileURL.standardizedFileURL.path),
      credentialIdentity: "replacement-access"
    ).credentialScopeID)
  }

  @Test func aChangedCanonicalSourceDoesNotHideTheCapturedFallback() async throws {
    let fixture = try makeChangedCanonicalFixture()

    await fixture.store.reloadAccounts()

    #expect(fixture.registry.load().count == 2)
    #expect(fixture.store.accounts[.claude]?.count == 2)
    #expect(fixture.store.accounts[.claude]?.contains {
      if case .claudeCredentialsFile = $0.credentialSource {
        return true
      }
      return false
    } == true)
  }
}

private struct ExistingSavedReplacementFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let selectionStore: ProviderAccountSelectionStore
  let store: UsageStore
  let freshAccessToken: String
}

@MainActor
private func makeExistingSavedReplacementFixture() async throws -> ExistingSavedReplacementFixture {
  let directory = try TemporaryDirectory()
  let codexDirectory = directory.url.appendingPathComponent(".codex", isDirectory: true)
  try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
  let authURL = codexDirectory.appendingPathComponent("auth.json")
  try writeRaceCodexCredentials(to: authURL, accountID: "account-a", email: "a@example.com")
  let freshAccessToken = raceJWT(exp: Date().addingTimeInterval(7200).timeIntervalSince1970)
  let registry = try existingSavedReplacementRegistry(
    authURL: authURL,
    accessToken: freshAccessToken
  )
  let baseDiscovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { nil },
    codexKeychainData: { _, _ in nil },
    capturedAccounts: registry
  )
  let selected = try #require(await baseDiscovery.accounts(for: .codex).first {
    !$0.credentialSource.isCaptured
  })
  let selectionStore = ProviderAccountSelectionStore(
    url: directory.url.appendingPathComponent("selection.json")
  )
  try selectionStore.save([.codex: selected])
  let discovery = ReplacingCodexDiscovery(
    base: baseDiscovery,
    authURL: authURL,
    replacementAccountID: "account-b",
    replacementEmail: "b@example.com",
    replacementAccessToken: raceJWT(exp: Date().addingTimeInterval(300).timeIntervalSince1970)
  )
  let store = UsageStore.isolatedForTesting(
    providers: [codexDescriptor()],
    accountDiscovery: discovery,
    accountSelectionStore: selectionStore,
    accountCapture: AccountCaptureService(capturedAccounts: registry),
    automaticallyCapturesDiscoveredAccounts: true,
    startsAutomatically: false
  )
  return ExistingSavedReplacementFixture(
    directory: directory,
    registry: registry,
    selectionStore: selectionStore,
    store: store,
    freshAccessToken: freshAccessToken
  )
}

private func existingSavedReplacementRegistry(
  authURL: URL,
  accessToken: String
) throws -> CapturedAccountStore {
  let registry = CapturedAccountStore.inMemoryForTesting()
  let payload = """
  {"tokens":{"access_token":"\(accessToken)","account_id":"account-b",\
  "email":"b@example.com","refresh_token":"saved-ref-b"}}
  """
  try registry.save(CapturedAccount(
    id: "codex:account-b",
    provider: .codex,
    displayName: "b@example.com",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .codexAuthFile(path: authURL.path),
    payload: Data(payload.utf8)
  ))
  return registry
}

private actor ReplacingCodexDiscovery: ProviderAccountDiscovering {
  private let base: ProviderAccountDiscovery
  private let authURL: URL
  private let replacementAccountID: String
  private let replacementEmail: String
  private let replacementAccessToken: String
  private var replaced = false

  init(
    base: ProviderAccountDiscovery,
    authURL: URL,
    replacementAccountID: String,
    replacementEmail: String,
    replacementAccessToken: String = "access"
  ) {
    self.base = base
    self.authURL = authURL
    self.replacementAccountID = replacementAccountID
    self.replacementEmail = replacementEmail
    self.replacementAccessToken = replacementAccessToken
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    let discovered = await base.accounts(for: provider)
    if provider == .codex, !replaced {
      replaced = true
      try? writeRaceCodexCredentials(
        to: authURL,
        accountID: replacementAccountID,
        email: replacementEmail,
        accessToken: replacementAccessToken
      )
    }
    return discovered
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    await base.liveAccount(equivalentTo: account, among: accounts)
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    await base.capturedCopies(among: accounts)
  }
}

private func writeRaceCodexCredentials(
  to url: URL,
  accountID: String,
  email: String,
  accessToken: String = "access"
) throws {
  let payload =
    #"{"tokens":{"access_token":"\#(accessToken)","account_id":"\#(accountID)","email":"\#(email)","refresh_token":"refresh"}}"#
  try Data(payload.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func raceJWT(exp: TimeInterval) -> String {
  func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
  let payload = base64URL((try? JSONSerialization.data(withJSONObject: ["exp": exp])) ?? Data())
  return "\(header).\(payload).sig"
}

private struct ClaudeDuplicateReplacementFixture {
  let directory: TemporaryDirectory
  let fileURL: URL
  let registry: CapturedAccountStore
  let discovery: GatedPostCaptureDiscovery
  let store: UsageStore
}

@MainActor
private func makeClaudeDuplicateReplacementFixture() throws -> ClaudeDuplicateReplacementFixture {
  let directory = try TemporaryDirectory()
  let claudeDirectory = directory.url.appendingPathComponent(".claude", isDirectory: true)
  try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
  let fileURL = claudeDirectory.appendingPathComponent(".credentials.json")
  try claudePayload(accessToken: "file-access", refreshToken: "file-refresh").write(to: fileURL)
  let keychainPayload = AutomaticCapturePayloadBox(
    claudePayload(accessToken: "keychain-access", refreshToken: "keychain-refresh")
  )
  let registry = CapturedAccountStore.inMemoryForTesting()
  let baseDiscovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { keychainPayload.value },
    capturedAccounts: registry
  )
  let discovery = GatedPostCaptureDiscovery(baseDiscovery)
  let store = UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in keychainPayload.value }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "keychain-access": ClaudeProfile(accountID: "account-a", email: "a@example.com"),
      "file-access": ClaudeProfile(accountID: "account-a", email: "a@example.com"),
      "replacement-access": ClaudeProfile(accountID: "account-b", email: "b@example.com"),
    ]),
    claudeCredentialLoader: { source in
      credentials(for: source, keychainPayload: keychainPayload, registry: registry)
    },
    startsAutomatically: false
  )
  return ClaudeDuplicateReplacementFixture(
    directory: directory,
    fileURL: fileURL,
    registry: registry,
    discovery: discovery,
    store: store
  )
}

private func credentials(
  for source: ProviderCredentialSource,
  keychainPayload: AutomaticCapturePayloadBox,
  registry: CapturedAccountStore
) -> ClaudeCredentials? {
  switch source {
  case .claudeKeychain:
    try? ClaudeCredentialsStore.parse(keychainPayload.value)
  case let .claudeCredentialsFile(path):
    (try? Data(contentsOf: URL(fileURLWithPath: path)))
      .flatMap { try? ClaudeCredentialsStore.parse($0) }
  case let .quotariRegistry(id):
    registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
  case .codexAuthFile, .codexKeychain, .claudeEnvironment:
    nil
  }
}

private struct ChangedCanonicalFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let store: UsageStore
}

@MainActor
private func makeChangedCanonicalFixture() throws -> ChangedCanonicalFixture {
  let directory = try TemporaryDirectory()
  let claudeDirectory = directory.url.appendingPathComponent(".claude", isDirectory: true)
  try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
  try claudePayload(accessToken: "file-access", refreshToken: "file-refresh")
    .write(to: claudeDirectory.appendingPathComponent(".credentials.json"))
  let keychainPayload = AutomaticCapturePayloadBox(
    claudePayload(accessToken: "keychain-access", refreshToken: "keychain-refresh")
  )
  let replacement = claudePayload(
    accessToken: "replacement-access",
    refreshToken: "replacement-refresh"
  )
  let registry = CapturedAccountStore.inMemoryForTesting()
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { keychainPayload.value },
    capturedAccounts: registry
  )
  let capture = AccountCaptureService(
    capturedAccounts: registry,
    claudeKeychainRead: { _ in
      keychainPayload.value = replacement
      return replacement
    }
  )
  let store = UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountCapture: capture,
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "keychain-access": ClaudeProfile(accountID: "account-a", email: "a@example.com"),
      "file-access": ClaudeProfile(accountID: "account-a", email: "a@example.com"),
      "replacement-access": ClaudeProfile(accountID: "account-b", email: "b@example.com"),
    ]),
    claudeCredentialLoader: { source in
      credentials(for: source, keychainPayload: keychainPayload, registry: registry)
    },
    startsAutomatically: false
  )
  return ChangedCanonicalFixture(directory: directory, registry: registry, store: store)
}
