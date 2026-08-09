// Capture and maintenance scenarios share the same credential fixtures.
// swiftlint:disable file_length
import Foundation
import CustomDump
@testable import QuotariCore
import Testing

private let codexPayload = #"{"tokens":{"access_token":"tok","account_id":"acct-1","refresh_token":"ref"}}"#
private let captureNow = Date(timeIntervalSince1970: 1000)

private func codexAuthFile(_ contents: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
  try Data(contents.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  return url
}

private func testJWT(exp: TimeInterval) -> String {
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

struct AccountCaptureServiceTests {
  @Test func capturesCodexFilePayloadIntoTheRegistry() throws {
    let url = try codexAuthFile(codexPayload)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: url.path)
    )

    let captured = try service.capture(account, now: captureNow)

    #expect(captured.provider == .codex)
    #expect(captured.id == "codex:acct-1") // keyed by account_id, so recapture updates
    #expect(store.load().count == 1)
    // The stored bytes parse back through the normal credential path.
    let credentials = try CodexCredentialsStore.load(source: .quotariRegistry(id: captured.id), capturedAccounts: store)
    #expect(credentials.accessToken == "tok")
    #expect(credentials.accountID == "acct-1")
  }

  @Test func recapturingSameIdentityUpdatesInPlace() throws {
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)

    let firstURL = try codexAuthFile(codexPayload)
    defer { try? FileManager.default.removeItem(at: firstURL) }
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: firstURL.path)
    )
    _ = try service.capture(account, now: captureNow)

    // Same account_id, rotated access token (a re-login).
    let secondURL =
      try codexAuthFile(#"{"tokens":{"access_token":"tok-2","account_id":"acct-1","refresh_token":"ref-2"}}"#)
    defer { try? FileManager.default.removeItem(at: secondURL) }
    let reloggedAccount = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: secondURL.path)
    )
    let updated = try service.capture(reloggedAccount, now: captureNow.addingTimeInterval(60))

    #expect(store.load().count == 1)
    #expect(try CodexCredentialsStore.load(
      source: .quotariRegistry(id: updated.id), capturedAccounts: store
    ).accessToken == "tok-2")
  }

  @Test func capturingAWorldReadableCodexFileIsRejected() throws {
    let url = try codexAuthFile(codexPayload)
    defer { try? FileManager.default.removeItem(at: url) }
    // Loosen permissions so the Codex loader's insecure-permissions guard trips.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    let service = AccountCaptureService(capturedAccounts: makeStore(InMemoryKeychain()))
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: url.path)
    )

    #expect(throws: AccountCaptureError.self) {
      _ = try service.capture(account, now: captureNow)
    }
  }

  @Test func capturingAnEnvironmentTokenIsRejected() {
    let service = AccountCaptureService(capturedAccounts: makeStore(InMemoryKeychain()))
    let account = ProviderAccount(
      provider: .claude, displayName: "Claude OAuth token", detail: "env",
      credentialSource: .claudeEnvironment(name: "QUOTARI_CLAUDE_OAUTH_TOKEN")
    )

    #expect(throws: AccountCaptureError.self) {
      _ = try service.capture(account, now: captureNow)
    }
  }

  @Test func capturesClaudeKeychainPayload() throws {
    let keychain = InMemoryKeychain()
    let claudePayload = #"{"claudeAiOauth":{"accessToken":"c-tok","refreshToken":"c-ref"}}"#
    let store = makeStore(keychain)
    let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
    let service = AccountCaptureService(
      capturedAccounts: store,
      claudeKeychainRead: { _ in Data(claudePayload.utf8) },
      makeUUID: { uuid }
    )
    let account = ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: "Keychain",
      credentialSource: .claudeKeychain(service: "Claude Code-credentials")
    )

    let captured = try service.capture(account, now: captureNow)

    #expect(captured.id == "claude:00000000-0000-0000-0000-000000000123")
    let credentials = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: captured.id), capturedAccounts: store
    )
    #expect(credentials.accessToken == "c-tok")
    #expect(credentials.refreshToken == "c-ref")
  }

  @Test func recapturingSameClaudeLoginDoesNotDuplicate() throws {
    let keychain = InMemoryKeychain()
    let store = makeStore(keychain)
    let service = AccountCaptureService(
      capturedAccounts: store,
      claudeKeychainRead: { _ in Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"stable-ref"}}"#.utf8) }
    )
    let account = ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: "Keychain",
      credentialSource: .claudeKeychain(service: "Claude Code-credentials")
    )

    _ = try service.capture(account, now: captureNow)
    _ = try service.capture(account, now: captureNow.addingTimeInterval(60))

    // Same refresh token ⇒ same identity ⇒ one entry, not two.
    #expect(store.load().count == 1)
  }
}

struct AccountCaptureStableIdentityTests {
  @Test func verifiedClaudeIdentityKeepsOneLocalRowAcrossTokenRotation() throws {
    let store = makeStore(InMemoryKeychain())
    let firstUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
    let secondUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000102"))
    let identity = ClaudeAccountIdentity(
      accountID: "ACCOUNT-A",
      email: "User@Example.com",
      organizationID: "ORG-A"
    )
    let first = try AccountCaptureService(capturedAccounts: store, makeUUID: { firstUUID })
      .captureRawPayload(
        provider: .claude,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: Data(#"{"claudeAiOauth":{"accessToken":"access-a","refreshToken":"refresh-a"}}"#.utf8),
        now: captureNow,
        claudeAccountIdentity: identity
      )
    let rotated = try AccountCaptureService(capturedAccounts: store, makeUUID: { secondUUID })
      .captureRawPayload(
        provider: .claude,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: Data(#"{"claudeAiOauth":{"accessToken":"access-b","refreshToken":"refresh-b"}}"#.utf8),
        now: captureNow.addingTimeInterval(60),
        claudeAccountIdentity: identity
      )

    let saved = try #require(rotated)
    expectNoDifference(store.load().map(\.id), ["claude:00000000-0000-0000-0000-000000000101"])
    #expect(first?.id == saved.id)
    expectNoDifference(saved.claudeAccountIdentity, identity)
    #expect(try ClaudeCredentialsStore.parse(saved.payload).refreshToken == "refresh-b")
  }

  @Test func weakRecaptureCannotDowngradeStrongIdentity() throws {
    let store = makeStore(InMemoryKeychain())
    let strong = ClaudeAccountIdentity(
      accountID: "account",
      email: "user@example.com",
      organizationID: "organization"
    )
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 501,
      identity: strong
    )

    let recaptured = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 502,
      identity: ClaudeAccountIdentity(email: "user@example.com")
    )

    #expect(recaptured.id == first.id)
    expectNoDifference(recaptured.claudeAccountIdentity, strong)
    #expect(store.load().count == 1)
  }

  @Test func strongRecaptureEnrichesWeakIdentityWithoutRekeying() throws {
    let store = makeStore(InMemoryKeychain())
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 511,
      identity: ClaudeAccountIdentity(email: "user@example.com")
    )
    let strong = ClaudeAccountIdentity(
      accountID: "account",
      email: "user@example.com",
      organizationID: "organization"
    )

    let recaptured = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 512,
      identity: strong
    )

    #expect(recaptured.id == first.id)
    expectNoDifference(recaptured.claudeAccountIdentity, strong)
    #expect(store.load().count == 1)
  }

  @Test func sameCredentialWithConflictingStrongIdentityFailsClosed() throws {
    let store = makeStore(InMemoryKeychain())
    let original = ClaudeAccountIdentity(accountID: "account-a", organizationID: "organization")
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 521,
      identity: original,
      accessToken: "original-access"
    )
    let originalPayload = first.payload

    #expect(throws: CapturedAccountStoreError.conflictingClaudeIdentity) {
      try captureClaudeTestRow(
        store: store,
        uuidSuffix: 522,
        identity: ClaudeAccountIdentity(accountID: "account-b", organizationID: "organization"),
        accessToken: "candidate-access"
      )
    }

    #expect(store.load().map(\.id) == [first.id])
    expectNoDifference(store.account(id: first.id)?.claudeAccountIdentity, original)
    expectNoDifference(store.account(id: first.id)?.payload, originalPayload)
    #expect(try ClaudeCredentialsStore.parse(originalPayload).accessToken == "original-access")
  }

  @Test func sameClaudeAccountInDifferentOrganizationsUsesSeparateRows() throws {
    let store = makeStore(InMemoryKeychain())
    let firstUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000201"))
    let secondUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000202"))
    _ = try AccountCaptureService(capturedAccounts: store, makeUUID: { firstUUID }).captureRawPayload(
      provider: .claude,
      origin: .claudeKeychain(service: "first"),
      payload: Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"ra"}}"#.utf8),
      now: captureNow,
      claudeAccountIdentity: ClaudeAccountIdentity(accountID: "acct", email: "same@example.com", organizationID: "org-a")
    )
    _ = try AccountCaptureService(capturedAccounts: store, makeUUID: { secondUUID }).captureRawPayload(
      provider: .claude,
      origin: .claudeKeychain(service: "second"),
      payload: Data(#"{"claudeAiOauth":{"accessToken":"b","refreshToken":"rb"}}"#.utf8),
      now: captureNow,
      claudeAccountIdentity: ClaudeAccountIdentity(accountID: "acct", email: "same@example.com", organizationID: "org-b")
    )

    expectNoDifference(
      store.load().map(\.id),
      [
        "claude:00000000-0000-0000-0000-000000000201",
        "claude:00000000-0000-0000-0000-000000000202",
      ]
    )
  }

  @Test func exactCredentialBackfillsIdentityWithoutRekeyingLegacyRow() throws {
    let store = makeStore(InMemoryKeychain())
    let payload = Data(#"{"claudeAiOauth":{"accessToken":"legacy-a","refreshToken":"legacy-r"}}"#.utf8)
    try store.save(CapturedAccount(
      id: "claude:fp:legacy",
      provider: .claude,
      displayName: "Claude Code",
      detail: "Saved in Quotari",
      capturedAt: captureNow,
      origin: .claudeKeychain(service: "legacy"),
      payload: payload
    ))
    let identity = ClaudeAccountIdentity(accountID: "acct", email: "user@example.com", organizationID: "org")
    let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000301"))

    let captured = try AccountCaptureService(capturedAccounts: store, makeUUID: { uuid }).captureRawPayload(
      provider: .claude,
      origin: .claudeKeychain(service: "legacy"),
      payload: payload,
      now: captureNow,
      claudeAccountIdentity: identity
    )

    #expect(captured?.id == "claude:fp:legacy")
    expectNoDifference(store.account(id: "claude:fp:legacy")?.claudeAccountIdentity, identity)
    #expect(store.load().count == 1)
  }

  @Test func uuidCaptureRetryRepairsConfirmedDanglingIndexEntry() throws {
    let keychain = InMemoryKeychain()
    let prefix = "Test-Capture-Dangling"
    let store = CapturedAccountStore(
      keychain: keychain.store,
      itemPrefix: prefix,
      indexService: "\(prefix)-Index"
    )
    let firstUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000401"))
    let secondUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000402"))
    let firstItem = "\(prefix).claude:00000000-0000-0000-0000-000000000401"
    let payload = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#.utf8)
    let identity = ClaudeAccountIdentity(accountID: "acct", organizationID: "org")
    keychain.failWrites(of: firstItem)

    #expect(throws: (any Error).self) {
      _ = try AccountCaptureService(capturedAccounts: store, makeUUID: { firstUUID }).captureRawPayload(
        provider: .claude,
        origin: .claudeKeychain(service: "Claude"),
        payload: payload,
        now: captureNow,
        claudeAccountIdentity: identity
      )
    }
    keychain.stopFailingWrites(of: firstItem)

    let retried = try AccountCaptureService(capturedAccounts: store, makeUUID: { secondUUID }).captureRawPayload(
      provider: .claude,
      origin: .claudeKeychain(service: "Claude"),
      payload: payload,
      now: captureNow,
      claudeAccountIdentity: identity
    )

    #expect(retried?.id == "claude:00000000-0000-0000-0000-000000000402")
    expectNoDifference(store.load().map(\.id), ["claude:00000000-0000-0000-0000-000000000402"])
    let indexData = try #require(try keychain.read("\(prefix)-Index"))
    let index = try #require(JSONSerialization.jsonObject(with: indexData) as? [String: Any])
    expectNoDifference(
      try #require(index["ids"] as? [String]),
      ["claude:00000000-0000-0000-0000-000000000402"]
    )
  }
}

struct AccountCaptureIdentityMergeTests {
  @Test func exactCredentialEnrichesEmailOnlyIdentityWithAccountUUID() throws {
    let store = makeStore(InMemoryKeychain())
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 521,
      identity: ClaudeAccountIdentity(email: "old@example.com"),
      accessToken: "old-access"
    )
    let enriched = ClaudeAccountIdentity(accountID: "account", email: "new@example.com")

    let recaptured = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 522,
      identity: enriched,
      accessToken: "new-access"
    )

    #expect(recaptured.id == first.id)
    expectNoDifference(recaptured.claudeAccountIdentity, enriched)
    #expect(store.load().count == 1)
  }

  @Test func exactCredentialEnrichesChangedEmailOnlyIdentityToStrong() throws {
    let store = makeStore(InMemoryKeychain())
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 523,
      identity: ClaudeAccountIdentity(email: "old@example.com"),
      accessToken: "old-access"
    )
    let strong = ClaudeAccountIdentity(
      accountID: "account",
      email: "new@example.com",
      organizationID: "organization"
    )

    let recaptured = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 524,
      identity: strong,
      accessToken: "new-access"
    )

    #expect(recaptured.id == first.id)
    expectNoDifference(recaptured.claudeAccountIdentity, strong)
    #expect(store.load().count == 1)
  }

  @Test func partialUUIDIdentityEnrichesToStrongIdentityWhenEmailChanges() throws {
    let store = makeStore(InMemoryKeychain())
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 531,
      identity: ClaudeAccountIdentity(accountID: "account", email: "old@example.com"),
      accessToken: "old-access"
    )
    let strong = ClaudeAccountIdentity(
      accountID: "account",
      email: "new@example.com",
      organizationID: "organization"
    )

    let recaptured = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 532,
      identity: strong,
      accessToken: "new-access"
    )

    #expect(recaptured.id == first.id)
    expectNoDifference(recaptured.claudeAccountIdentity, strong)
    #expect(try ClaudeCredentialsStore.parse(recaptured.payload).accessToken == "new-access")
    #expect(store.load().count == 1)
  }

  @Test func sameStrongIdentityUpdatesChangedEmailAcrossTokenRotation() throws {
    let store = makeStore(InMemoryKeychain())
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 541,
      identity: ClaudeAccountIdentity(
        accountID: "account",
        email: "old@example.com",
        organizationID: "organization"
      ),
      accessToken: "old-access",
      refreshToken: "old-refresh"
    )
    let updatedIdentity = ClaudeAccountIdentity(
      accountID: "account",
      email: "new@example.com",
      organizationID: "organization"
    )

    let recaptured = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 542,
      identity: updatedIdentity,
      accessToken: "new-access",
      refreshToken: "new-refresh"
    )

    #expect(recaptured.id == first.id)
    expectNoDifference(recaptured.claudeAccountIdentity, updatedIdentity)
    #expect(try ClaudeCredentialsStore.parse(recaptured.payload).refreshToken == "new-refresh")
    #expect(store.load().count == 1)
  }

  @Test func missingIncomingEmailPreservesStoredStrongIdentityEmail() throws {
    let store = makeStore(InMemoryKeychain())
    let originalIdentity = ClaudeAccountIdentity(
      accountID: "account",
      email: "keep@example.com",
      organizationID: "organization"
    )
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 551,
      identity: originalIdentity,
      accessToken: "old-access",
      refreshToken: "old-refresh"
    )

    let recaptured = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 552,
      identity: ClaudeAccountIdentity(accountID: "account", organizationID: "organization"),
      accessToken: "new-access",
      refreshToken: "new-refresh"
    )

    #expect(recaptured.id == first.id)
    expectNoDifference(recaptured.claudeAccountIdentity, originalIdentity)
    #expect(store.load().count == 1)
  }

  @Test func sameAccountInDifferentOrganizationCannotOverwriteExactCredential() throws {
    let store = makeStore(InMemoryKeychain())
    let originalIdentity = ClaudeAccountIdentity(
      accountID: "account",
      email: "user@example.com",
      organizationID: "organization-a"
    )
    let first = try captureClaudeTestRow(
      store: store,
      uuidSuffix: 561,
      identity: originalIdentity,
      accessToken: "old-access"
    )
    let originalPayload = first.payload

    #expect(throws: CapturedAccountStoreError.conflictingClaudeIdentity) {
      try captureClaudeTestRow(
        store: store,
        uuidSuffix: 562,
        identity: ClaudeAccountIdentity(
          accountID: "account",
          email: "user@example.com",
          organizationID: "organization-b"
        ),
        accessToken: "new-access"
      )
    }

    #expect(store.load().map(\.id) == [first.id])
    expectNoDifference(store.account(id: first.id)?.claudeAccountIdentity, originalIdentity)
    expectNoDifference(store.account(id: first.id)?.payload, originalPayload)
  }
}

struct AccountCapturePayloadTests {
  @Test func claudeCaptureDropsUnrelatedMcpSecrets() throws {
    let keychain = InMemoryKeychain()
    let store = makeStore(keychain)
    let fullPayload = """
    {
      "claudeAiOauth": {"accessToken": "c-tok", "refreshToken": "c-ref"},
      "mcpOAuth": {"linear|abc": {"accessToken": "SECRET-mcp-token"}}
    }
    """
    let service = AccountCaptureService(
      capturedAccounts: store,
      claudeKeychainRead: { _ in Data(fullPayload.utf8) }
    )
    let account = ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: "Keychain",
      credentialSource: .claudeKeychain(service: "Claude Code-credentials")
    )

    let captured = try service.capture(account, now: captureNow)
    let storedText = String(data: captured.payload, encoding: .utf8) ?? ""

    #expect(!storedText.contains("mcpOAuth"))
    #expect(!storedText.contains("SECRET-mcp-token"))
    #expect(storedText.contains("c-tok"))
  }

  @Test func minimizerRejectsWrongShapedPayloads() {
    // Wrong-shaped nested values must not be stored as usable snapshots.
    #expect(ProviderCredentialMinimizer.minimize(provider: .codex, payload: Data(#"{"tokens":"nope"}"#.utf8)) == nil)
    #expect(ProviderCredentialMinimizer
      .minimize(provider: .claude, payload: Data(#"{"claudeAiOauth":42}"#.utf8)) == nil)
    #expect(ProviderCredentialMinimizer.minimize(provider: .codex, payload: Data(#"{"tokens":{}}"#.utf8)) == nil)
    #expect(ProviderCredentialMinimizer.minimize(provider: .claude, payload: Data("not json".utf8)) == nil)
  }

  @Test func minimizerDropsRootSiblingsButKeepsTheProviderObject() throws {
    // Root-level siblings (other services' secrets) are dropped; the whole
    // claudeAiOauth object — including the refresh token — is preserved so a
    // saved account stays renewable.
    let payload = Data("""
    {"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["s"],
     "subscriptionType":"max","rateLimitTier":"t"},
     "mcpOAuth":{"x":{"accessToken":"MCP"}}}
    """.utf8)
    let minimal = try #require(ProviderCredentialMinimizer.minimize(provider: .claude, payload: payload))
    let text = String(data: minimal, encoding: .utf8) ?? ""

    #expect(!text.contains("mcpOAuth"))
    #expect(!text.contains("MCP"))
    #expect(text.contains("refreshToken"))
    #expect(text.contains("rateLimitTier"))
  }

  @Test func codexMinimizerKeepsRefreshTokenAndDropsRootApiKey() throws {
    // Real Codex auth.json shape: OPENAI_API_KEY and last_refresh are root
    // siblings. Drop the unrelated API key, but retain both tokens and their
    // refresh timestamp because Codex requires last_refresh to load them.
    let payload = Data("""
    {"tokens":{"access_token":"a","account_id":"acct","id_token":"jwt","refresh_token":"REFRESH"},
     "OPENAI_API_KEY":"sk-KEEP-OUT","last_refresh":"2026-01-01"}
    """.utf8)
    let minimal = try #require(ProviderCredentialMinimizer.minimize(provider: .codex, payload: payload))
    let text = String(data: minimal, encoding: .utf8) ?? ""

    #expect(!text.contains("OPENAI_API_KEY"))
    #expect(!text.contains("sk-KEEP-OUT"))
    #expect(text.contains("last_refresh"))
    #expect(text.contains("2026-01-01"))
    #expect(text.contains("refresh_token"))
    #expect(text.contains("REFRESH"))
    #expect(text.contains("account_id"))
  }

  @Test func codexMinimizerPreservesDeepTokenFieldsWithoutKeepingRootSiblings() throws {
    let nested = String(repeating: "[", count: 5000) + "null" + String(repeating: "]", count: 5000)
    let payload = Data(
      #"{"unknown":\#(nested),"tokens":{"access_token":"a","refresh_token":"r","future":\#(nested)}}"#.utf8
    )

    let minimal = try #require(ProviderCredentialMinimizer.minimize(provider: .codex, payload: payload))
    let fields = try #require(CodexJSONProjector.topLevelFields(minimal))
    let tokenFields = try #require(fields["tokens"].flatMap(CodexJSONProjector.topLevelFields))

    #expect(fields["unknown"] == nil)
    #expect(tokenFields["future"] == Data(nested.utf8))
    #expect(try CodexCredentialsStore.parse(minimal).refreshToken == "r")
  }

  @Test func codexEmptyAccountIDFallsBackAndDoesNotCollide() throws {
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)

    let urlA =
      try codexAuthFile(#"{"tokens":{"access_token":"t-a","account_id":"  ","id_token":"","refresh_token":"ref-a"}}"#)
    let urlB = try codexAuthFile(#"{"tokens":{"access_token":"t-b","account_id":"","refresh_token":"ref-b"}}"#)
    defer {
      try? FileManager.default.removeItem(at: urlA)
      try? FileManager.default.removeItem(at: urlB)
    }
    let capturedA = try service.capture(ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "A",
      credentialSource: .codexAuthFile(path: urlA.path)
    ), now: captureNow)
    let capturedB = try service.capture(ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "B",
      credentialSource: .codexAuthFile(path: urlB.path)
    ), now: captureNow.addingTimeInterval(1))

    // Empty/whitespace account_id must NOT collapse two different logins onto
    // one "codex:" id — each gets a distinct UUID-based entry.
    #expect(capturedA.id != capturedB.id)
    #expect(store.load().count == 2)
  }

  @Test func recapturingAnIDLessCodexLoginReusesItsLegacyUUIDEntry() throws {
    let store = makeStore(InMemoryKeychain())
    let legacyID = "codex:550e8400-e29b-41d4-a716-446655440000"
    try store.save(CapturedAccount(
      id: legacyID,
      provider: .codex,
      displayName: "Codex account",
      detail: "Default",
      capturedAt: captureNow,
      origin: .codexAuthFile(path: "/tmp/legacy-auth.json"),
      payload: Data(#"{"tokens":{"access_token":"old-token","refresh_token":"stable-refresh"}}"#.utf8)
    ))
    let liveURL = try codexAuthFile(
      #"{"tokens":{"access_token":"new-token","refresh_token":"stable-refresh"}}"#
    )
    defer { try? FileManager.default.removeItem(at: liveURL) }
    let service = AccountCaptureService(capturedAccounts: store)

    let captured = try service.capture(ProviderAccount(
      provider: .codex,
      displayName: "Codex account",
      detail: "Default",
      credentialSource: .codexAuthFile(path: liveURL.path)
    ), now: captureNow.addingTimeInterval(60))

    #expect(captured.id == legacyID)
    #expect(store.load().map(\.id) == [legacyID])
    let credentials = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: legacyID),
      capturedAccounts: store
    )
    #expect(credentials.accessToken == "new-token")
    #expect(credentials.refreshToken == "stable-refresh")
  }

  @Test func capturingAPayloadWithoutARefreshTokenIsRejected() throws {
    // A snapshot that can't renew itself would die at its first expiry —
    // the same reason env tokens aren't capturable.
    let url = try codexAuthFile(#"{"tokens":{"access_token":"tok","account_id":"acct-1"}}"#)
    defer { try? FileManager.default.removeItem(at: url) }
    let service = AccountCaptureService(capturedAccounts: makeStore(InMemoryKeychain()))
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: url.path)
    )

    #expect(throws: AccountCaptureError.noRefreshToken) {
      try service.capture(account, now: captureNow)
    }
  }

  @Test func minimizerRequiresARefreshToken() {
    #expect(ProviderCredentialMinimizer.minimize(
      provider: .claude,
      payload: Data(#"{"claudeAiOauth":{"accessToken":"a"}}"#.utf8)
    ) == nil)
    #expect(ProviderCredentialMinimizer.minimize(
      provider: .codex,
      payload: Data(#"{"tokens":{"access_token":"a","refresh_token":""}}"#.utf8)
    ) == nil)
  }
}

private func makeStore(_ keychain: InMemoryKeychain) -> CapturedAccountStore {
  CapturedAccountStore(keychain: keychain.store, service: "Test-Capture-\(UUID().uuidString)")
}

private func captureClaudeTestRow(
  store: CapturedAccountStore,
  uuidSuffix: Int,
  identity: ClaudeAccountIdentity,
  accessToken: String = "access",
  refreshToken: String = "refresh"
) throws -> CapturedAccount {
  let suffix = String(format: "%012d", uuidSuffix)
  let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-\(suffix)"))
  let captured = try AccountCaptureService(capturedAccounts: store, makeUUID: { uuid }).captureRawPayload(
    provider: .claude,
    origin: .claudeKeychain(service: "Claude"),
    payload: Data(
      #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
    ),
    now: captureNow,
    claudeAccountIdentity: identity
  )
  return try #require(captured)
}

/// Upkeep of saved copies while their identity is the live CLI login.
struct AccountCaptureCopyMaintenanceTests {
  @Test func syncKeepsAHiddenSavedCopyTrackingTheLiveRotation() throws {
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)
    let firstURL = try codexAuthFile(codexPayload)
    defer { try? FileManager.default.removeItem(at: firstURL) }
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: firstURL.path)
    )
    _ = try service.capture(account, now: captureNow)

    // The CLI rotates its tokens while the identity stays the same; the
    // hidden saved copy must follow, or it dies when the slot moves on.
    let rotatedURL = try codexAuthFile(
      #"{"tokens":{"access_token":"tok-9","account_id":"acct-1","refresh_token":"ref-9"}}"#
    )
    defer { try? FileManager.default.removeItem(at: rotatedURL) }
    let rotatedAccount = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: rotatedURL.path)
    )

    service.syncCapturedCopies(of: [rotatedAccount])

    let credentials = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"), capturedAccounts: store
    )
    #expect(credentials.accessToken == "tok-9")
    #expect(credentials.refreshToken == "ref-9")
  }

  @Test func syncNeverLetsAStaleSlotClobberAFresherSavedPair() throws {
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)
    let freshJWT = testJWT(exp: 100_000)
    let staleJWT = testJWT(exp: 1000)
    let freshURL = try codexAuthFile(
      #"{"tokens":{"access_token":"\#(freshJWT)","account_id":"acct-1","refresh_token":"ref-new"}}"#
    )
    defer { try? FileManager.default.removeItem(at: freshURL) }
    _ = try service.capture(ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: freshURL.path)
    ), now: captureNow)

    // A second slot with the same identity still holds the older pair.
    let staleURL = try codexAuthFile(
      #"{"tokens":{"access_token":"\#(staleJWT)","account_id":"acct-1","refresh_token":"ref-old"}}"#
    )
    defer { try? FileManager.default.removeItem(at: staleURL) }
    service.syncCapturedCopies(of: [ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "CODEX_HOME",
      credentialSource: .codexAuthFile(path: staleURL.path)
    )])

    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"), capturedAccounts: store
    )
    #expect(saved.accessToken == freshJWT)
    #expect(saved.refreshToken == "ref-new")
  }
}
