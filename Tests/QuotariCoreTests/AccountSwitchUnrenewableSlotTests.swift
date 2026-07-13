import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchUnrenewableSlotTests {
  private struct CodexSwitchFixture {
    var service: AccountSwitchService
    var home: URL
    var authURL: URL
  }

  @Test func claudeAccessOnlyLoginIsNotOverwritten() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let original = Data(#"{"claudeAiOauth":{"accessToken":"live-only"}}"#.utf8)
    let slot = KeychainSlot(original)
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
    #expect(slot.value == original)
    #expect(registry.load().count == 1)
  }

  @Test func codexAccessOnlyLoginIsNotOverwritten() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let fixture = try codexService(
      registry: registry,
      payload: Data(#"{"tokens":{"access_token":"live-only","account_id":"acct-live"}}"#.utf8)
    )
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let original = try Data(contentsOf: fixture.authURL)

    #expect(throws: AccountSwitchError.self) {
      try fixture.service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    }
    #expect(try Data(contentsOf: fixture.authURL) == original)
    #expect(registry.load().count == 1)
  }

  @Test func codexAPIKeyOnlyLoginRemainsAvailableAfterSwitching() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let fixture = try codexService(
      registry: registry,
      payload: Data(#"{"OPENAI_API_KEY":"sk-live","auth_mode":"apikey"}"#.utf8)
    )
    defer { try? FileManager.default.removeItem(at: fixture.home) }

    try fixture.service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.authURL)) as? [String: Any]
    #expect(root?["OPENAI_API_KEY"] as? String == "sk-live")
    #expect(root?["auth_mode"] as? String == "chatgpt")
    #expect((root?["tokens"] as? [String: Any])?["account_id"] as? String == "acct-saved")
  }

  private func codexService(
    registry: CapturedAccountStore,
    payload: Data
  ) throws -> CodexSwitchFixture {
    let home = try switchTemporaryHome()
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try payload.write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )
    return CodexSwitchFixture(service: service, home: home, authURL: authURL)
  }
}
