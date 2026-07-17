import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchClaudeBackupIdentityTests {
  @Test func switchingBackUsesTheTerminalIdentityBackedUpWithTheLiveCredential() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let livePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"live-tok","refreshToken":"live-ref","expiresAt":1000}}"#.utf8
    )
    try livePayload.write(to: fileURL)
    let stateURL = home.appendingPathComponent(".claude.json")
    try Data(
      #"{"oauthAccount":{"accountUuid":"live-id","emailAddress":"live@example.com"}}"#.utf8
    ).write(to: stateURL)
    let keychain = KeychainSlot(livePayload)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in keychain.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in keychain.value = data }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let fingerprint = ProviderCredentialIdentity.claudeIdentity(
      refreshToken: "live-ref",
      accessToken: "live-tok"
    )
    let backedUp = try #require(registry.load().first { $0.id == "claude:\(fingerprint ?? "")" })
    let backedUpOAuthAccount = try #require(backedUp.claudeOAuthAccount)
    #expect(ClaudeCodeAccountState.matches(
      backedUpOAuthAccount,
      profile: ClaudeProfile(accountID: "live-id", email: "live@example.com")
    ))

    // No profile is supplied for the reverse switch: the exact identity must
    // survive with the credential so a profile endpoint outage cannot strand it.
    try service.switchCLI(toRegistryAccount: backedUp.id, now: Date(timeIntervalSince1970: 6000))
    let restoredOAuthAccount = try #require(
      try ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL))
    )
    #expect(ClaudeCodeAccountState.matches(
      restoredOAuthAccount,
      profile: ClaudeProfile(accountID: "live-id", email: "live@example.com")
    ))
  }

  @Test func invalidKeychainBacksUpTheFileAsCanonicalTerminalIdentity() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let livePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"file-tok","refreshToken":"file-ref","expiresAt":1000}}"#.utf8
    )
    try livePayload.write(to: fileURL)
    let stateURL = home.appendingPathComponent(".claude.json")
    try Data(
      #"{"oauthAccount":{"accountUuid":"file-id","emailAddress":"file@example.com"}}"#.utf8
    ).write(to: stateURL)
    let keychain = KeychainSlot(Data(#"{"notClaudeOAuth":true}"#.utf8))
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in keychain.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in keychain.value = data }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let fingerprint = ProviderCredentialIdentity.claudeIdentity(
      refreshToken: "file-ref",
      accessToken: "file-tok"
    )
    let backedUp = try #require(registry.load().first { $0.id == "claude:\(fingerprint ?? "")" })
    let backedUpOAuthAccount = try #require(backedUp.claudeOAuthAccount)
    #expect(ClaudeCodeAccountState.matches(
      backedUpOAuthAccount,
      profile: ClaudeProfile(accountID: "file-id", email: "file@example.com")
    ))

    try service.switchCLI(toRegistryAccount: backedUp.id, now: Date(timeIntervalSince1970: 6000))
    let restoredOAuthAccount = try #require(
      try ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL))
    )
    #expect(ClaudeCodeAccountState.matches(
      restoredOAuthAccount,
      profile: ClaudeProfile(accountID: "file-id", email: "file@example.com")
    ))
  }
}
