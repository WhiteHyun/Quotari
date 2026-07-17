import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchClaudeAccountStateTests {
  @Test func legacyAccountWithoutAVerifiedIdentityFailsBeforeCredentialWrites() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry, claudeOAuthAccount: nil)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let configurationURL = home.appendingPathComponent(".claude.json")
    let configuration = accountState(id: "old", email: "old@example.com")
    try writeAccountState(configuration, to: configurationURL)
    let live = claudePayload(access: "live", refresh: "live-ref")
    let keychain = KeychainSlot(live)
    let service = switcher(registry: registry, home: home, keychain: keychain)

    let thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
      thrown = nil
    } catch let error as AccountSwitchError {
      thrown = error
    }
    guard case .claudeAccountIdentityUnavailable = thrown else {
      Issue.record("expected .claudeAccountIdentityUnavailable, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == live)
    #expect(try Data(contentsOf: configurationURL) == configuration)
  }

  @Test func legacySavedAccountUpdatesTheTerminalIdentity() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry, claudeOAuthAccount: nil)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let configurationURL = home.appendingPathComponent(".claude.json")
    try writeAccountState(Data(#"""
    {"theme":"dark","oauthAccount":{"accountUuid":"syh2-id","emailAddress":"syh2@example.com",
     "organizationName":"Acme","organizationUuid":"org-id","subscriptionType":"team"}}
    """#.utf8), to: configurationURL)
    let slot = KeychainSlot(claudePayload(access: "syh2-token", refresh: "syh2-refresh"))
    let service = switcher(registry: registry, home: home, keychain: slot)

    try service.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 5000),
      targetClaudeProfile: ClaudeProfile(
        accountID: "hsh-id",
        email: "hsh@example.com",
        organizationName: "Acme"
      )
    )

    let root = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL)) as? [String: Any]
    )
    let oauth = try #require(root["oauthAccount"] as? [String: Any])
    let keychainData = try #require(slot.value)
    let keychain = try #require(JSONSerialization.jsonObject(with: keychainData) as? [String: Any])
    let keychainOAuth = try #require(keychain["claudeAiOauth"] as? [String: Any])
    #expect(root["theme"] as? String == "dark")
    #expect(oauth["accountUuid"] as? String == "hsh-id")
    #expect(oauth["emailAddress"] as? String == "hsh@example.com")
    #expect(oauth["organizationUuid"] as? String == "org-id")
    #expect(oauth["subscriptionType"] == nil)
    #expect(keychainOAuth["accessToken"] as? String == "saved-tok")
  }

  @Test func terminalIdentityRaceRollsBackTheCredentialSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let configurationURL = home.appendingPathComponent(".claude.json")
    try writeAccountState(accountState(id: "old", email: "old@example.com"), to: configurationURL)
    let concurrent = accountState(id: "external", email: "external@example.com")
    let live = claudePayload(access: "live", refresh: "live-ref")
    let keychain = KeychainSlot(live)
    let interlock = AccountStateInterlock(check: 3) {
      try writeAccountState(concurrent, to: configurationURL)
    }
    let service = switcher(
      registry: registry,
      home: home,
      keychain: keychain,
      activeCLIProcesses: interlock.inspect
    )

    let thrown: AccountSwitchError?
    do {
      try service.switchCLI(
        toRegistryAccount: saved.id,
        now: .distantPast,
        targetClaudeProfile: ClaudeProfile(accountID: "target", email: "target@example.com")
      )
      thrown = nil
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .concurrentCredentialChange = thrown else {
      Issue.record("expected .concurrentCredentialChange, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == live)
    #expect(try Data(contentsOf: configurationURL) == concurrent)
  }

  @Test(arguments: [2, 3])
  func preparationFailureCleansEarlierCredentialTemporaryFiles(failingPreparation: Int) throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
    let credentialsURL = claudeDirectory.appendingPathComponent(".credentials.json")
    let fileCredential = claudePayload(access: "file", refresh: "file-ref")
    try writeAccountState(fileCredential, to: credentialsURL)
    try writeAccountState(
      accountState(id: "old", email: "old@example.com"),
      to: home.appendingPathComponent(".claude.json")
    )
    let live = claudePayload(access: "live", refresh: "live-ref")
    let keychain = KeychainSlot(live)
    let permissions = AccountStatePermissionFailure(failingPreparation: failingPreparation)
    let service = switcher(
      registry: registry,
      home: home,
      keychain: keychain,
      setOwnerOnlyPermissions: permissions.apply
    )

    #expect(throws: AccountSwitchError.self) {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    }

    #expect(keychain.value == live)
    #expect(try Data(contentsOf: credentialsURL) == fileCredential)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: claudeDirectory.path)
      .filter { $0.contains("quotari") }
    #expect(leftovers.isEmpty)
  }

  private func switcher(
    registry: CapturedAccountStore,
    home: URL,
    keychain: KeychainSlot,
    activeCLIProcesses: @escaping @Sendable (UsageProvider) throws -> [String] = { _ in [] },
    setOwnerOnlyPermissions: (@Sendable (URL) throws -> Void)? = nil
  ) -> AccountSwitchService {
    AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in keychain.value }
      ),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in keychain.value = data },
      activeCLIProcesses: activeCLIProcesses,
      setOwnerOnlyPermissions: setOwnerOnlyPermissions
    )
  }
}

private final class AccountStatePermissionFailure: @unchecked Sendable {
  private let lock = NSLock()
  private let failingPreparation: Int
  private var preparation = 0

  init(failingPreparation: Int) {
    self.failingPreparation = failingPreparation
  }

  func apply(_: URL) throws {
    let shouldFail = lock.withLock {
      preparation += 1
      return preparation == failingPreparation
    }
    if shouldFail {
      throw CocoaError(.fileWriteNoPermission)
    }
  }
}

private final class AccountStateInterlock: @unchecked Sendable {
  private let lock = NSLock()
  private let targetCheck: Int
  private let action: @Sendable () throws -> Void
  private var checkCount = 0

  init(check: Int, action: @escaping @Sendable () throws -> Void) {
    targetCheck = check
    self.action = action
  }

  func inspect(_: UsageProvider) throws -> [String] {
    let shouldRun = lock.withLock {
      checkCount += 1
      return checkCount == targetCheck
    }
    if shouldRun {
      try action()
    }
    return []
  }
}

private func writeAccountState(_ data: Data, to url: URL) throws {
  try data.write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func accountState(id: String, email: String) -> Data {
  Data(#"{"oauthAccount":{"accountUuid":"\#(id)","emailAddress":"\#(email)"}}"#.utf8)
}

private func claudePayload(access: String, refresh: String) -> Data {
  Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8)
}
