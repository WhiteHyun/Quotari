import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchTransplantTests {
  @Test func claudeTransplantKeepsForeignRootKeys() throws {
    let live = Data(#"""
    {"claudeAiOauth": {"accessToken": "live-tok", "refreshToken": "live-ref"},
     "mcpOAuth": {"github": {"accessToken": "gh-tok"}}}
    """#.utf8)
    let saved = Data(#"{"claudeAiOauth":{"accessToken":"saved-tok","refreshToken":"saved-ref"}}"#.utf8)

    let merged = try AccountSwitchService.transplantClaude(saved: saved, intoLive: live)

    let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
    let oauth = root?["claudeAiOauth"] as? [String: Any]
    #expect(oauth?["accessToken"] as? String == "saved-tok")
    #expect(oauth?["refreshToken"] as? String == "saved-ref")
    #expect((root?["mcpOAuth"] as? [String: Any])?.keys.contains("github") == true)
  }

  @Test func codexTransplantForcesChatGPTAuthAndPreservesAPIKey() throws {
    // Switching from an API-key login: the tokens are transplanted and
    // auth_mode is forced to chatgpt (so Codex uses the switched-in account),
    // but OPENAI_API_KEY is PRESERVED — deleting it would permanently lose an
    // API-key login the backup path can't snapshot. Non-auth siblings survive.
    let live = Data(#"""
    {"OPENAI_API_KEY": "sk-key", "auth_mode": "apikey", "last_refresh": "2026-01-01T00:00:00Z"}
    """#.utf8)
    let saved = Data(#"""
    {"tokens":{"access_token":"saved-tok","account_id":"acct-saved","refresh_token":"saved-ref"},
     "last_refresh":"2025-12-31T00:00:00Z"}
    """#.utf8)

    let merged = try AccountSwitchService.transplantCodex(saved: saved, intoLive: live)

    let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
    let tokens = root?["tokens"] as? [String: Any]
    #expect(tokens?["access_token"] as? String == "saved-tok")
    #expect(tokens?["account_id"] as? String == "acct-saved")
    #expect(root?["auth_mode"] as? String == "chatgpt")
    #expect(root?["OPENAI_API_KEY"] as? String == "sk-key")
    #expect(root?["last_refresh"] as? String == "2025-12-31T00:00:00Z")
  }

  @Test func transplantIntoAnEmptySlotWritesTheSavedCredential() throws {
    let saved = Data(#"{"tokens":{"access_token":"saved-tok","account_id":"a","refresh_token":"r"}}"#.utf8)
    let merged = try AccountSwitchService.transplantCodex(saved: saved, intoLive: nil)
    let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
    #expect((root?["tokens"] as? [String: Any])?["access_token"] as? String == "saved-tok")
    #expect(root?["last_refresh"] as? String == "1970-01-01T00:00:00Z")
  }

  @Test func codexTransplantPreservesADeepUnknownLiveField() throws {
    let nested = String(repeating: "[", count: 5000) + "null" + String(repeating: "]", count: 5000)
    let live = Data(#"{"OPENAI_API_KEY":"sk-live","unknown":\#(nested)}"#.utf8)
    let saved = Data(
      #"{"tokens":{"access_token":"saved","refresh_token":"saved-ref"}}"#.utf8
    )

    let merged = try AccountSwitchService.transplantCodex(saved: saved, intoLive: live)
    let fields = try #require(CodexJSONProjector.topLevelFields(merged))

    #expect(fields["OPENAI_API_KEY"] == Data(#""sk-live""#.utf8))
    #expect(fields["unknown"] == Data(nested.utf8))
    #expect(try CodexCredentialsStore.parse(merged).accessToken == "saved")
  }
}

struct AccountSwitchServiceTests {
  @Test func codexSwitchWritesSavedTokensAndBacksUpTheCurrentLogin() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(#"""
    {"tokens": {"access_token": "live-tok", "account_id": "acct-live", "refresh_token": "live-ref"},
     "OPENAI_API_KEY": "sk-key"}
    """#.utf8).write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    // The slot now holds the saved account's tokens with ChatGPT auth mode;
    // the API key is preserved (auth_mode governs which Codex uses).
    let slot = try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
    #expect((slot?["tokens"] as? [String: Any])?["account_id"] as? String == "acct-saved")
    #expect(slot?["auth_mode"] as? String == "chatgpt")
    #expect(slot?["OPENAI_API_KEY"] as? String == "sk-key")
    // The previous login was captured — switching back stays possible.
    let backedUp = registry.load().first { $0.id == "codex:acct-live" }
    #expect(backedUp != nil)
    let credentials = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-live"), capturedAccounts: registry
    )
    #expect(credentials.accessToken == "live-tok")
    #expect(credentials.refreshToken == "live-ref")
  }

  @Test func codexSwitchIntoAnEmptySlotJustWrites() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let authURL = home.appendingPathComponent(".codex/auth.json")
    let slot = try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
    #expect((slot?["tokens"] as? [String: Any])?["account_id"] as? String == "acct-saved")
    #expect(registry.load().count == 1) // nothing to back up
  }

  @Test func codexSwitchPrefersTheCodexHomeSlot() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    let codexHome = try switchTemporaryHome()
    defer {
      try? FileManager.default.removeItem(at: home)
      try? FileManager.default.removeItem(at: codexHome)
    }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: ["CODEX_HOME": codexHome.path],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    #expect(FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path))
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path))
  }

  @Test func claudeSwitchRewritesKeychainAndCredentialsFile() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let livePayload = #"""
    {"claudeAiOauth": {"accessToken": "live-tok", "refreshToken": "live-ref", "expiresAt": 1000},
     "mcpOAuth": {"github": {"accessToken": "gh"}}}
    """#
    try Data(livePayload.utf8).write(to: fileURL)
    let slot = KeychainSlot(Data(livePayload.utf8))
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    // Keychain and file both hold the saved account, mcpOAuth preserved.
    for payload in [slot.value, try? Data(contentsOf: fileURL)] {
      let root = try JSONSerialization.jsonObject(with: #require(payload)) as? [String: Any]
      #expect((root?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "saved-tok")
      #expect((root?["mcpOAuth"] as? [String: Any])?.keys.contains("github") == true)
    }
    // The previous login was captured under its refresh-token fingerprint.
    let fingerprint = ProviderCredentialIdentity.claudeIdentity(refreshToken: "live-ref", accessToken: "live-tok")
    #expect(registry.load().contains { $0.id == "claude:\(fingerprint ?? "")" })
  }

  @Test func switchAbortsWithTheSlotUntouchedWhenTheBackupWriteFails() throws {
    // A real renewable login is in the slot, but the registry's keychain
    // refuses writes — the backup can't be persisted, so the switch must
    // abort before overwriting the slot (fail closed).
    let keychain = InMemoryKeychain()
    let service = "Test-Switch-\(UUID().uuidString)"
    let registry = CapturedAccountStore(keychain: keychain.store, service: service)
    let saved = try savedCodexAccount(registry: registry)
    keychain.failWrites(of: "\(service)-Index") // any registry save now throws
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(#"{"tokens":{"access_token":"live-tok","account_id":"acct-live","refresh_token":"live-ref"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let switcher = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    #expect(throws: AccountSwitchError.self) {
      try switcher.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    }

    // The slot is untouched — the switch failed closed.
    let slot = try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
    #expect((slot?["tokens"] as? [String: Any])?["account_id"] as? String == "acct-live")
  }

  @Test func switchAbortsWhenTheSlotCannotBeRead() throws {
    // A slot file exists but can't be read — never mistaken for empty; the
    // switch aborts rather than overwrite an unreadable login.
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let switcher = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in throw KeychainItemStore.KeychainError.commandFailed(status: 36) },
      keychainWrite: { _, _ in Issue.record("must not write after a read failure") }
    )

    #expect(throws: AccountSwitchError.self) {
      try switcher.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    }
  }

  @Test func switchRefreshesAnAlreadySavedLoginInPlaceWithoutDuplicating() throws {
    // The live login is already saved — but with an OLD pair. The switch must
    // re-capture the CURRENT live pair (the CLI may have rotated it since),
    // updating the same registry id rather than trusting the stale copy.
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    try registry.save(CapturedAccount(
      id: "codex:acct-live",
      provider: .codex,
      displayName: "Live Codex",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 100),
      origin: .codexAuthFile(path: "/tmp/live.json"),
      payload: Data(#"{"tokens":{"access_token":"old-tok","account_id":"acct-live","refresh_token":"old-ref"}}"#.utf8)
    ))
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // The live slot holds a NEWER pair than the saved copy.
    try Data(#"{"tokens":{"access_token":"new-tok","account_id":"acct-live","refresh_token":"new-ref"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    #expect(registry.load().count == 2) // updated in place, no duplicate
    let backed = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-live"), capturedAccounts: registry
    )
    #expect(backed.accessToken == "new-tok") // the fresh pair, not the stale one
    #expect(backed.refreshToken == "new-ref")
  }

  @Test func claudeSwitchBacksUpBothDivergentStores() throws {
    // Keychain holds login A, the credentials file holds a DIFFERENT login B.
    // Both are overwritten, so both must be preserved.
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(#"{"claudeAiOauth":{"accessToken":"tok-B","refreshToken":"ref-B"}}"#.utf8).write(to: fileURL)
    let slot = KeychainSlot(Data(#"{"claudeAiOauth":{"accessToken":"tok-A","refreshToken":"ref-A"}}"#.utf8))
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let fpA = ProviderCredentialIdentity.claudeIdentity(refreshToken: "ref-A", accessToken: "tok-A")
    let fpB = ProviderCredentialIdentity.claudeIdentity(refreshToken: "ref-B", accessToken: "tok-B")
    let ids = Set(registry.load().map(\.id))
    #expect(ids.contains("claude:\(fpA ?? "")"))
    #expect(ids.contains("claude:\(fpB ?? "")"))
  }

  @Test func claudeSwitchRollsBackTheKeychainWhenTheFileWriteFails() throws {
    // The keychain write lands but the file write fails; the keychain is
    // rolled back so the two stores don't disagree, and both logins remain
    // backed up regardless.
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    let claudeDir = home.appendingPathComponent(".claude")
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claudeDir.path)
      try? FileManager.default.removeItem(at: home)
    }
    // The file is readable, but its parent is made read-only so the atomic
    // write (temp-file + rename in that dir) fails.
    let fileURL = claudeDir.appendingPathComponent(".credentials.json")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try Data(#"{"claudeAiOauth":{"accessToken":"file-tok","refreshToken":"file-ref"}}"#.utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: claudeDir.path)
    let liveKeychain = #"{"claudeAiOauth":{"accessToken":"live-tok","refreshToken":"live-ref"}}"#
    let slot = KeychainSlot(Data(liveKeychain.utf8))
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    #expect(throws: AccountSwitchError.self) {
      try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    }

    // Keychain restored to the live login (no half-applied switch).
    let restored = try JSONSerialization.jsonObject(with: #require(slot.value)) as? [String: Any]
    #expect((restored?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "live-tok")
    // The live login was still preserved.
    let fp = ProviderCredentialIdentity.claudeIdentity(refreshToken: "live-ref", accessToken: "live-tok")
    #expect(registry.load().contains { $0.id == "claude:\(fp ?? "")" })
  }
}
