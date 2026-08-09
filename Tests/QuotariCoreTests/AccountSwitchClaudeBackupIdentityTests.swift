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
    let profile = strongClaudeProfile("live")
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in keychain.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in keychain.value = data }
    )

    try switchClaudeWithVerifiedLiveIdentity(
      service,
      to: saved.id,
      source: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      accessToken: "live-tok",
      profile: profile
    )

    let backedUp = try capturedClaudeAccount(
      registry: registry,
      refreshToken: "live-ref"
    )
    #expect(backedUp.id.hasPrefix("claude:"))
    #expect(backedUp.claudeAccountIdentity == profile.accountIdentity)
    try expectClaudeIdentity(backedUp.claudeOAuthAccount, accountID: "live-id", email: "live@example.com")

    // No profile is supplied for the reverse switch: the exact identity must
    // survive with the credential so a profile endpoint outage cannot strand it.
    try service.switchCLI(toRegistryAccount: backedUp.id, now: Date(timeIntervalSince1970: 6000))
    try expectClaudeIdentity(
      ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL)),
      accountID: "live-id",
      email: "live@example.com"
    )
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
    let profile = strongClaudeProfile("file")
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in keychain.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in keychain.value = data }
    )

    try switchClaudeWithVerifiedLiveIdentity(
      service,
      to: saved.id,
      source: .claudeCredentialsFile(path: fileURL.standardizedFileURL.path),
      accessToken: "file-tok",
      profile: profile
    )

    let backedUp = try capturedClaudeAccount(
      registry: registry,
      refreshToken: "file-ref"
    )
    #expect(backedUp.id.hasPrefix("claude:"))
    #expect(backedUp.claudeAccountIdentity == profile.accountIdentity)
    try expectClaudeIdentity(backedUp.claudeOAuthAccount, accountID: "file-id", email: "file@example.com")

    try service.switchCLI(toRegistryAccount: backedUp.id, now: Date(timeIntervalSince1970: 6000))
    try expectClaudeIdentity(
      ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL)),
      accountID: "file-id",
      email: "file@example.com"
    )
  }

  @Test func verifiedLiveTargetKeepsItsTrustedIdentityWhenTerminalStateIsStale() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let livePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"rotated-tok","refreshToken":"rotated-ref","expiresAt":8000000000000}}"#
        .utf8
    )
    let stateURL = home.appendingPathComponent(".claude.json")
    try Data(
      #"{"oauthAccount":{"accountUuid":"stale-id","emailAddress":"stale@example.com"}}"#.utf8
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

    try service.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 5000),
      knownLiveTarget: KnownLiveClaudeTarget(
        source: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        accessTokenFingerprint: ProviderCredentialIdentity.fingerprint(of: "rotated-tok")
      )
    )

    let refreshed = try #require(registry.account(id: saved.id))
    let trustedIdentity = try #require(refreshed.claudeOAuthAccount)
    #expect(ClaudeCodeAccountState.matches(
      trustedIdentity,
      profile: ClaudeProfile(accountID: "saved-id", email: "saved@example.com")
    ))
    let installedIdentity = try #require(
      try ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL))
    )
    #expect(ClaudeCodeAccountState.matches(
      installedIdentity,
      profile: ClaudeProfile(accountID: "saved-id", email: "saved@example.com")
    ))
  }
}

struct AccountSwitchClaudeBackupStateTests {
  @Test func switchBackupPreservesAnExistingIdentityOverStaleTerminalState() throws {
    let registry = makeSwitchRegistry()
    let switchTarget = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let livePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"live-tok","refreshToken":"live-ref","expiresAt":8000000000000}}"#
        .utf8
    )
    let fingerprint = ProviderCredentialIdentity.claudeIdentity(
      refreshToken: "live-ref",
      accessToken: "live-tok"
    )
    let existingID = "claude:\(fingerprint ?? "")"
    try registry.save(CapturedAccount(
      id: existingID,
      provider: .claude,
      displayName: "Existing Claude",
      detail: "Keychain",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: livePayload,
      claudeOAuthAccount: Data(
        #"{"accountUuid":"live-id","emailAddress":"live@example.com"}"#.utf8
      )
    ))
    let stateURL = home.appendingPathComponent(".claude.json")
    try Data(
      #"{"oauthAccount":{"accountUuid":"stale-id","emailAddress":"stale@example.com"}}"#.utf8
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

    try service.switchCLI(toRegistryAccount: switchTarget.id, now: Date(timeIntervalSince1970: 5000))

    let backedUp = try #require(registry.account(id: existingID))
    try expectClaudeIdentity(backedUp.claudeOAuthAccount, accountID: "live-id", email: "live@example.com")

    try service.switchCLI(toRegistryAccount: existingID, now: Date(timeIntervalSince1970: 6000))
    try expectClaudeIdentity(
      ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL)),
      accountID: "live-id",
      email: "live@example.com"
    )
  }

  @Test func fileTargetDoesNotDropADivergentCanonicalKeychainIdentity() throws {
    let registry = makeSwitchRegistry()
    let target = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let targetPayload = claudeSwitchPayload(accessToken: "rotated-target", refreshToken: "rotated-target-ref")
    try targetPayload.write(to: fileURL)
    let otherPayload = claudeSwitchPayload(accessToken: "other-tok", refreshToken: "other-ref")
    let otherProfile = strongClaudeProfile("other")
    let stateURL = home.appendingPathComponent(".claude.json")
    try Data(
      #"{"oauthAccount":{"accountUuid":"other-id","emailAddress":"other@example.com"}}"#.utf8
    ).write(to: stateURL)
    let keychain = KeychainSlot(otherPayload)
    let service = makeClaudeBackupSwitchService(registry: registry, home: home, keychain: keychain)
    let fileSource = ProviderCredentialSource.claudeCredentialsFile(
      path: fileURL.standardizedFileURL.path
    )

    try service.switchCLI(
      toRegistryAccount: target.id,
      now: Date(timeIntervalSince1970: 5000),
      knownLiveTarget: KnownLiveClaudeTarget(
        source: fileSource,
        accessTokenFingerprint: ProviderCredentialIdentity.fingerprint(of: "rotated-target")
      ),
      verifiedLiveClaudeIdentity: verifiedClaudeLiveIdentity(
        source: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        accessToken: "other-tok",
        profile: otherProfile
      )
    )

    let other = try capturedClaudeAccount(registry: registry, refreshToken: "other-ref")
    #expect(other.claudeAccountIdentity == otherProfile.accountIdentity)
    try expectClaudeIdentity(
      other.claudeOAuthAccount,
      accountID: "other-id",
      email: "other@example.com"
    )
    try service.switchCLI(toRegistryAccount: other.id, now: Date(timeIntervalSince1970: 6000))
    try expectClaudeIdentity(
      ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: stateURL)),
      accountID: "other-id",
      email: "other@example.com"
    )
  }
}
