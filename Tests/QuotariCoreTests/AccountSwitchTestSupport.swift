import Foundation
@testable import QuotariCore
import Testing

/// An in-memory Claude-keychain slot the switch can read and write.
final class KeychainSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Data?

  init(_ initial: Data? = nil) {
    storage = initial
  }

  var value: Data? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

func makeSwitchRegistry() -> CapturedAccountStore {
  CapturedAccountStore(keychain: InMemoryKeychain().store, service: "Test-Switch-\(UUID().uuidString)")
}

func savedCodexAccount(registry: CapturedAccountStore) throws -> CapturedAccount {
  let saved = CapturedAccount(
    id: "codex:acct-saved",
    provider: .codex,
    displayName: "Saved Codex",
    detail: "Personal",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .codexAuthFile(path: "/tmp/old.json"),
    payload: Data(#"{"tokens":{"access_token":"saved-tok","account_id":"acct-saved","refresh_token":"saved-ref"}}"#
      .utf8)
  )
  try registry.save(saved)
  return saved
}

func savedClaudeAccount(registry: CapturedAccountStore) throws -> CapturedAccount {
  let saved = CapturedAccount(
    id: "claude:fp-saved",
    provider: .claude,
    displayName: "Saved Claude",
    detail: "Keychain",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: "Claude Code-credentials"),
    payload: Data(#"{"claudeAiOauth":{"accessToken":"saved-tok","refreshToken":"saved-ref","expiresAt":9999999999999}}"#
      .utf8)
  )
  try registry.save(saved)
  return saved
}

func switchTemporaryHome() throws -> URL {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("switch-home-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}
