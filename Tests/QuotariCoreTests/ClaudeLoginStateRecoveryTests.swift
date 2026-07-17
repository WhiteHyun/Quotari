import Foundation
@testable import QuotariCore
import Testing

struct ClaudeLoginStateRecoveryTests {
  @Test func restoresKeychainAndAccountStateFromTheSameBoundary() throws {
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let stateURL = home.appendingPathComponent(".claude.json")
    let previousState = recoveryAccountState(id: "previous", email: "previous@example.com")
    let installedState = recoveryAccountState(id: "installed", email: "installed@example.com")
    try installedState.write(to: stateURL)
    let previousKeychain = recoveryClaudePayload(access: "previous", refresh: "previous-ref")
    let installedKeychain = recoveryClaudePayload(access: "installed", refresh: "installed-ref")
    let keychain = KeychainSlot(installedKeychain)
    let registry = makeSwitchRegistry()
    let service = recoveryService(registry: registry, home: home, keychain: keychain)

    try service.restoreClaudeLogin(keychain: previousKeychain, accountState: previousState)

    #expect(keychain.value == previousKeychain)
    #expect(try Data(contentsOf: stateURL) == previousState)
    let savedInstalled = try #require(registry.load().first(where: { account in
      (try? ClaudeCredentialsStore.parse(account.payload).accessToken) == "installed"
    }))
    #expect(savedInstalled.claudeOAuthAccount == nil)
  }

  @Test func doesNotAttachStaleAccountStateToThePostLoginCredentialBackup() throws {
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let stateURL = home.appendingPathComponent(".claude.json")
    let previousState = recoveryAccountState(id: "previous", email: "previous@example.com")
    let staleInstalledState = recoveryAccountState(id: "syh2", email: "syh2@example.com")
    try staleInstalledState.write(to: stateURL)
    let previousKeychain = recoveryClaudePayload(access: "previous", refresh: "previous-ref")
    let hshKeychain = recoveryClaudePayload(access: "hsh", refresh: "hsh-ref")
    let keychain = KeychainSlot(hshKeychain)
    let registry = makeSwitchRegistry()
    let service = recoveryService(registry: registry, home: home, keychain: keychain)

    try service.restoreClaudeLogin(keychain: previousKeychain, accountState: previousState)

    let savedHSH = try #require(registry.load().first(where: { account in
      (try? ClaudeCredentialsStore.parse(account.payload).accessToken) == "hsh"
    }))
    #expect(savedHSH.claudeOAuthAccount == nil)
  }

  @Test func accountStateRaceRollsTheKeychainBackToThePostLoginValue() throws {
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let stateURL = home.appendingPathComponent(".claude.json")
    let previousState = recoveryAccountState(id: "previous", email: "previous@example.com")
    let installedState = recoveryAccountState(id: "installed", email: "installed@example.com")
    let concurrentState = recoveryAccountState(id: "concurrent", email: "concurrent@example.com")
    try installedState.write(to: stateURL)
    let previousKeychain = recoveryClaudePayload(access: "previous", refresh: "previous-ref")
    let installedKeychain = recoveryClaudePayload(access: "installed", refresh: "installed-ref")
    let keychain = KeychainSlot(installedKeychain)
    let registry = makeSwitchRegistry()
    let interlock = RecoveryActivityInterlock(check: 4) {
      try concurrentState.write(to: stateURL)
    }
    let service = recoveryService(
      registry: registry,
      home: home,
      keychain: keychain,
      activeCLIProcesses: interlock.inspect
    )

    #expect(throws: AccountSwitchError.self) {
      try service.restoreClaudeLogin(keychain: previousKeychain, accountState: previousState)
    }

    #expect(keychain.value == installedKeychain)
    #expect(try Data(contentsOf: stateURL) == concurrentState)
  }

  @Test func signedOutBoundaryRemovesAccountStateCreatedByFailedLogin() throws {
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let stateURL = home.appendingPathComponent(".claude.json")
    try recoveryAccountState(id: "installed", email: "installed@example.com").write(to: stateURL)
    let installedKeychain = recoveryClaudePayload(access: "installed", refresh: "installed-ref")
    let keychain = KeychainSlot(installedKeychain)
    let registry = makeSwitchRegistry()
    let service = recoveryService(registry: registry, home: home, keychain: keychain)

    try service.restoreClaudeLogin(keychain: nil, accountState: nil)

    #expect(keychain.value == nil)
    #expect(!FileManager.default.fileExists(atPath: stateURL.path))
  }
}

private func recoveryService(
  registry: CapturedAccountStore,
  home: URL,
  keychain: KeychainSlot,
  activeCLIProcesses: @escaping @Sendable (UsageProvider) throws -> [String] = { _ in [] }
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
    keychainDelete: { _ in keychain.value = nil },
    activeCLIProcesses: activeCLIProcesses
  )
}

private final class RecoveryActivityInterlock: @unchecked Sendable {
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

private func recoveryAccountState(id: String, email: String) -> Data {
  Data(#"{"oauthAccount":{"accountUuid":"\#(id)","emailAddress":"\#(email)"}}"#.utf8)
}

private func recoveryClaudePayload(access: String, refresh: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8
  )
}
