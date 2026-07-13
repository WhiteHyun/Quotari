import Foundation
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
    let service = AccountCaptureService(
      capturedAccounts: store,
      claudeKeychainRead: { _ in Data(claudePayload.utf8) }
    )
    let account = ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: "Keychain",
      credentialSource: .claudeKeychain(service: "Claude Code-credentials")
    )

    let captured = try service.capture(account, now: captureNow)

    #expect(captured.id.hasPrefix("claude:fp:"))
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
    // siblings; the tokens object (incl. refresh_token) must survive so the
    // saved account can refresh a stale session.
    let payload = Data("""
    {"tokens":{"access_token":"a","account_id":"acct","id_token":"jwt","refresh_token":"REFRESH"},
     "OPENAI_API_KEY":"sk-KEEP-OUT","last_refresh":"2026-01-01"}
    """.utf8)
    let minimal = try #require(ProviderCredentialMinimizer.minimize(provider: .codex, payload: payload))
    let text = String(data: minimal, encoding: .utf8) ?? ""

    #expect(!text.contains("OPENAI_API_KEY"))
    #expect(!text.contains("sk-KEEP-OUT"))
    #expect(!text.contains("last_refresh"))
    #expect(text.contains("refresh_token"))
    #expect(text.contains("REFRESH"))
    #expect(text.contains("account_id"))
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

  @Test func removeCapturedCopyWorksWithoutARefreshToken() throws {
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)
    let savedURL = try codexAuthFile(codexPayload)
    defer { try? FileManager.default.removeItem(at: savedURL) }
    _ = try service.capture(ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: savedURL.path)
    ), now: captureNow)

    // The CLI slot's current payload lost its refresh token; identity alone
    // must still be enough to delete the saved copy it hides.
    let bareURL = try codexAuthFile(#"{"tokens":{"access_token":"tok-2","account_id":"acct-1"}}"#)
    defer { try? FileManager.default.removeItem(at: bareURL) }

    let removed = try service.removeCapturedCopy(of: ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: bareURL.path)
    ))

    #expect(removed == "codex:acct-1")
    #expect(store.load().isEmpty)
  }

  @Test func removeCapturedCopyDeletesTheSavedCopyOfALiveIdentity() throws {
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)
    let url = try codexAuthFile(codexPayload)
    defer { try? FileManager.default.removeItem(at: url) }
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: url.path)
    )
    _ = try service.capture(account, now: captureNow)
    #expect(store.load().count == 1)

    let removed = try service.removeCapturedCopy(of: account)

    #expect(removed == "codex:acct-1")
    #expect(store.load().isEmpty)
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
