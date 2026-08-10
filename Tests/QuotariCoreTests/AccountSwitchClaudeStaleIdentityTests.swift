import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchClaudeStaleIdentityTests {
  @Test func newCredentialDoesNotInheritAStableButStaleTerminalIdentity() throws {
    let registry = makeSwitchRegistry()
    let switchTarget = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let livePayload = claudeSwitchPayload(accessToken: "new-tok", refreshToken: "new-ref")
    let stateURL = home.appendingPathComponent(".claude.json")
    try Data(
      #"{"oauthAccount":{"accountUuid":"old-id","emailAddress":"old@example.com"}}"#.utf8
    ).write(to: stateURL)
    let keychain = KeychainSlot(livePayload)
    let service = makeClaudeBackupSwitchService(registry: registry, home: home, keychain: keychain)

    try switchClaudeWithVerifiedLiveIdentity(
      service,
      to: switchTarget.id,
      source: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      accessToken: "new-tok",
      profile: ClaudeProfile(
        accountID: "new-id",
        email: "new@example.com",
        organizationID: "new-org"
      )
    )

    let backedUp = try capturedClaudeAccount(registry: registry, refreshToken: "new-ref")
    #expect(backedUp.claudeAccountIdentity == ClaudeAccountIdentity(
      accountID: "new-id",
      email: "new@example.com",
      organizationID: "new-org"
    ))
    #expect(backedUp.claudeOAuthAccount == nil)

    #expect(throws: AccountSwitchError.self) {
      try service.switchCLI(
        toRegistryAccount: backedUp.id,
        now: Date(timeIntervalSince1970: 6000)
      )
    }
    try expectClaudeIdentity(
      ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL)),
      accountID: "saved-id",
      email: "saved@example.com"
    )
  }
}
