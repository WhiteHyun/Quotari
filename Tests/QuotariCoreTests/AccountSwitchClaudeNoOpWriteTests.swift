import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchClaudeNoOpWriteTests {
  @Test func claudeSwitchToTheLoginAlreadyLiveNeverRewritesTheKeychain() throws {
    // Account login re-syncs the login the CLI just wrote. The transplant
    // re-serializes JSON, so without a semantic no-op check it would rewrite
    // identical credentials and race the CLI's own keychain writes.
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let livePayload = Data(#"""
    {"mcpOAuth": {"github": {"accessToken": "gh"}},
     "claudeAiOauth": {"accessToken": "saved-tok", "refreshToken": "saved-ref", "expiresAt": 9999999999999}}
    """#.utf8)
    let slot = KeychainSlot(livePayload)
    let writes = KeychainSlot()
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in
        writes.value = data
        throw KeychainItemStore.KeychainError.commandFailed(status: 1)
      }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    #expect(writes.value == nil)
    #expect(slot.value == livePayload)
  }
}
