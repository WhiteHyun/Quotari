import Foundation
@testable import QuotariCore
import Testing

struct AccountCaptureServiceTests {
  private static let codexPayload = #"{"tokens":{"access_token":"tok","account_id":"acct-1"}}"#
  private static let now = Date(timeIntervalSince1970: 1000)

  private func codexAuthFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  @Test func capturesCodexFilePayloadIntoTheRegistry() throws {
    let url = try codexAuthFile(Self.codexPayload)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: url.path)
    )

    let captured = try service.capture(account, now: Self.now)

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

    let firstURL = try codexAuthFile(Self.codexPayload)
    defer { try? FileManager.default.removeItem(at: firstURL) }
    let account = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: firstURL.path)
    )
    _ = try service.capture(account, now: Self.now)

    // Same account_id, rotated access token (a re-login).
    let secondURL = try codexAuthFile(#"{"tokens":{"access_token":"tok-2","account_id":"acct-1"}}"#)
    defer { try? FileManager.default.removeItem(at: secondURL) }
    let reloggedAccount = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Default",
      credentialSource: .codexAuthFile(path: secondURL.path)
    )
    let updated = try service.capture(reloggedAccount, now: Self.now.addingTimeInterval(60))

    #expect(store.load().count == 1)
    #expect(try CodexCredentialsStore.load(
      source: .quotariRegistry(id: updated.id), capturedAccounts: store
    ).accessToken == "tok-2")
  }

  @Test func capturingAnEnvironmentTokenIsRejected() {
    let service = AccountCaptureService(capturedAccounts: makeStore(InMemoryKeychain()))
    let account = ProviderAccount(
      provider: .claude, displayName: "Claude OAuth token", detail: "env",
      credentialSource: .claudeEnvironment(name: "QUOTARI_CLAUDE_OAUTH_TOKEN")
    )

    #expect(throws: AccountCaptureError.self) {
      _ = try service.capture(account, now: Self.now)
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

    let captured = try service.capture(account, now: Self.now)

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

    _ = try service.capture(account, now: Self.now)
    _ = try service.capture(account, now: Self.now.addingTimeInterval(60))

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

    let captured = try service.capture(account, now: Self.now)
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

  @Test func minimizerKeepsOnlyAllowedFields() throws {
    let payload = Data("""
    {"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["s"],
     "subscriptionType":"max","rateLimitTier":"t","unknownSecret":"KEEP-OUT"},
     "mcpOAuth":{"x":{"accessToken":"MCP"}}}
    """.utf8)
    let minimal = try #require(ProviderCredentialMinimizer.minimize(provider: .claude, payload: payload))
    let text = String(data: minimal, encoding: .utf8) ?? ""

    #expect(!text.contains("unknownSecret"))
    #expect(!text.contains("KEEP-OUT"))
    #expect(!text.contains("mcpOAuth"))
    #expect(text.contains("refreshToken"))
    #expect(text.contains("rateLimitTier"))
  }

  @Test func codexMinimizerKeepsOnlyTokenFields() throws {
    let payload = Data("""
    {"tokens":{"access_token":"a","account_id":"acct","id_token":"jwt","OPENAI_API_KEY":"sk-KEEP-OUT"},
     "last_refresh":"2026-01-01"}
    """.utf8)
    let minimal = try #require(ProviderCredentialMinimizer.minimize(provider: .codex, payload: payload))
    let text = String(data: minimal, encoding: .utf8) ?? ""

    #expect(!text.contains("OPENAI_API_KEY"))
    #expect(!text.contains("sk-KEEP-OUT"))
    #expect(!text.contains("last_refresh"))
    #expect(text.contains("account_id"))
    #expect(text.contains("id_token"))
  }

  @Test func minimizerDropsTypeConfusedValuesUnderAllowedKeys() throws {
    // A wrong-typed value under an allowed key must not ride along.
    let payload = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":{"nested":"OBJECT"}}}"#.utf8)
    let minimal = try #require(ProviderCredentialMinimizer.minimize(provider: .claude, payload: payload))
    let text = String(data: minimal, encoding: .utf8) ?? ""

    #expect(!text.contains("nested"))
    #expect(!text.contains("OBJECT"))
    #expect(text.contains("\"accessToken\":\"a\""))
  }

  @Test func codexEmptyAccountIDFallsBackAndDoesNotCollide() throws {
    let store = makeStore(InMemoryKeychain())
    let service = AccountCaptureService(capturedAccounts: store)

    let urlA = try codexAuthFile(#"{"tokens":{"access_token":"t-a","account_id":"  ","id_token":""}}"#)
    let urlB = try codexAuthFile(#"{"tokens":{"access_token":"t-b","account_id":""}}"#)
    defer {
      try? FileManager.default.removeItem(at: urlA)
      try? FileManager.default.removeItem(at: urlB)
    }
    let capturedA = try service.capture(ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "A",
      credentialSource: .codexAuthFile(path: urlA.path)
    ), now: Self.now)
    let capturedB = try service.capture(ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "B",
      credentialSource: .codexAuthFile(path: urlB.path)
    ), now: Self.now.addingTimeInterval(1))

    // Empty/whitespace account_id must NOT collapse two different logins onto
    // one "codex:" id — each gets a distinct UUID-based entry.
    #expect(capturedA.id != capturedB.id)
    #expect(store.load().count == 2)
  }
}

private func makeStore(_ keychain: InMemoryKeychain) -> CapturedAccountStore {
  CapturedAccountStore(keychain: keychain.store, service: "Test-Capture-\(UUID().uuidString)")
}
