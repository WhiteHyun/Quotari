import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchConcurrencyReviewTests {
  @Test func codexKeyringSwitchQuarantinesAndRemovesTheVerifiedOAuthFallback() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let codexDirectory = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    try Data("cli_auth_credentials_store = \"keyring\"\n".utf8)
      .write(to: codexDirectory.appendingPathComponent("config.toml"))
    let authURL = codexDirectory.appendingPathComponent("auth.json")
    let fallback = reviewCodexPayload(account: "acct-file", token: "file", refresh: "file-ref")
    try writeReviewCredential(fallback, to: authURL)
    let keychain = CodexKeychainSlot(
      reviewCodexPayload(account: "acct-key", token: "key", refresh: "key-ref")
    )
    let service = AccountSwitchService(
      capturedAccounts: registry,
      environment: [:],
      home: home,
      codexKeychainRead: keychain.read,
      codexKeychainWrite: keychain.write,
      codexKeychainDelete: { service, account in
        keychain.delete(service: service, account: account)
      }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)

    #expect(!FileManager.default.fileExists(atPath: authURL.path))
    #expect(try CodexCredentialsStore.parse(#require(keychain.value)).accountID == "acct-saved")
  }

  @Test func claudeFileOnlySwitchRejectsANewHigherPrecedenceKeychain() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try writeReviewCredential(reviewClaudePayload(access: "live", refresh: "live-ref"), to: fileURL)
    let keychain = KeychainSlot()
    let newer = reviewClaudePayload(access: "newer", refresh: "newer-ref")
    let interlock = ReviewActivityInterlock(check: 3) { keychain.value = newer }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in keychain.value }
      ),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in keychain.value = data },
      activeCLIProcesses: interlock.inspect
    )

    let thrown = captureReviewSwitchError(service, accountID: saved.id)

    guard case .partialSwitch = thrown else {
      Issue.record("expected .partialSwitch, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == newer)
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fileURL)).accessToken == "saved-tok")
  }

  @Test func codexAutoFileSwitchRejectsANewHigherPrecedenceKeyring() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let codexDirectory = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    try Data("cli_auth_credentials_store = \"auto\"\n".utf8)
      .write(to: codexDirectory.appendingPathComponent("config.toml"))
    let authURL = codexDirectory.appendingPathComponent("auth.json")
    try writeReviewCredential(
      reviewCodexPayload(account: "acct-file", token: "file", refresh: "file-ref"),
      to: authURL
    )
    let keychain = CodexKeychainSlot()
    let newer = reviewCodexPayload(account: "acct-new", token: "new", refresh: "new-ref")
    let interlock = ReviewActivityInterlock(check: 3) {
      try keychain.write(newer, service: "Codex Auth", account: "test")
    }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      environment: [:],
      home: home,
      codexKeychainRead: keychain.read,
      codexKeychainWrite: keychain.write,
      codexKeychainDelete: { service, account in
        keychain.delete(service: service, account: account)
      },
      activeCLIProcesses: interlock.inspect
    )

    let thrown = captureReviewSwitchError(service, accountID: saved.id)

    guard case .partialSwitch = thrown else {
      Issue.record("expected .partialSwitch, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == newer)
    #expect(try CodexCredentialsStore.load(url: authURL).accountID == "acct-saved")
  }

  @Test func claudeVerificationReadFailureAfterWriteIsPartial() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let keychain = FailingClaudeKeychainSlot(
      reviewClaudePayload(access: "live", refresh: "live-ref"),
      failAfterWriteRead: 1
    )
    let service = reviewClaudeService(registry: registry, home: home, keychain: keychain)

    let thrown = captureReviewSwitchError(service, accountID: saved.id)

    guard case .partialSwitch = thrown else {
      Issue.record("expected .partialSwitch, got \(String(describing: thrown))")
      return
    }
    #expect(try ClaudeCredentialsStore.parse(#require(keychain.value)).accessToken == "saved-tok")
  }

  @Test func claudeRollbackGuardReadFailureIsPartial() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let claudeDirectory = home.appendingPathComponent(".claude")
    let fileURL = claudeDirectory.appendingPathComponent(".credentials.json")
    try writeReviewCredential(reviewClaudePayload(access: "file", refresh: "file-ref"), to: fileURL)
    let keychain = FailingClaudeKeychainSlot(
      reviewClaudePayload(access: "key", refresh: "key-ref"),
      failAfterWriteRead: 3
    )
    let service = reviewClaudeService(
      registry: registry,
      home: home,
      keychain: keychain,
      afterWrite: {
        let temporaryNames = try FileManager.default.contentsOfDirectory(atPath: claudeDirectory.path)
          .filter { $0.hasPrefix(".credentials.json.quotari.") }
        for name in temporaryNames {
          try FileManager.default.removeItem(at: claudeDirectory.appendingPathComponent(name))
        }
      }
    )

    let thrown = captureReviewSwitchError(service, accountID: saved.id)

    guard case .partialSwitch = thrown else {
      Issue.record("expected .partialSwitch, got \(String(describing: thrown))")
      return
    }
    #expect(try ClaudeCredentialsStore.parse(#require(keychain.value)).accessToken == "saved-tok")
  }

  @Test func claudeFileReadFailureAfterKeychainWriteRollsBack() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try writeReviewCredential(reviewClaudePayload(access: "file", refresh: "file-ref"), to: fileURL)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    let keychain = FailingClaudeKeychainSlot(
      reviewClaudePayload(access: "key", refresh: "key-ref"),
      failAfterWriteRead: .max
    )
    let service = reviewClaudeService(
      registry: registry,
      home: home,
      keychain: keychain,
      afterWrite: {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
      }
    )

    let thrown = captureReviewSwitchError(service, accountID: saved.id)

    guard case .writeFailed = thrown else {
      Issue.record("expected .writeFailed after rollback, got \(String(describing: thrown))")
      return
    }
    #expect(try ClaudeCredentialsStore.parse(#require(keychain.value)).accessToken == "key")
  }
}

private func captureReviewSwitchError(
  _ service: AccountSwitchService,
  accountID: String
) -> AccountSwitchError? {
  do {
    try service.switchCLI(toRegistryAccount: accountID, now: .distantPast)
    return nil
  } catch let error as AccountSwitchError {
    return error
  } catch {
    Issue.record("expected AccountSwitchError, got \(error)")
    return nil
  }
}

private func reviewClaudeService(
  registry: CapturedAccountStore,
  home: URL,
  keychain: FailingClaudeKeychainSlot,
  afterWrite: (@Sendable () throws -> Void)? = nil
) -> AccountSwitchService {
  AccountSwitchService(
    capturedAccounts: registry,
    capture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { service in try? keychain.read(service) }
    ),
    environment: [:],
    home: home,
    keychainRead: keychain.read,
    keychainWrite: { data, service in
      keychain.write(data, service: service)
      try afterWrite?()
    }
  )
}

private final class FailingClaudeKeychainSlot: @unchecked Sendable {
  private let lock = NSLock()
  private let failAfterWriteRead: Int
  private var storage: Data?
  private var didWrite = false
  private var readsAfterWrite = 0

  init(_ value: Data?, failAfterWriteRead: Int) {
    storage = value
    self.failAfterWriteRead = failAfterWriteRead
  }

  func read(_: String) throws -> Data? {
    try lock.withLock {
      if didWrite {
        readsAfterWrite += 1
        if readsAfterWrite == failAfterWriteRead {
          throw KeychainItemStore.KeychainError.commandFailed(status: 36)
        }
      }
      return storage
    }
  }

  func write(_ data: Data, service _: String) {
    lock.withLock {
      storage = data
      didWrite = true
    }
  }

  var value: Data? {
    lock.withLock { storage }
  }
}

private final class ReviewActivityInterlock: @unchecked Sendable {
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

private func writeReviewCredential(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func reviewCodexPayload(account: String, token: String, refresh: String) -> Data {
  let idToken = "e30.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.sig"
  return Data(
    #"{"tokens":{"id_token":"\#(idToken)","access_token":"\#(token)","account_id":"\#(account)","refresh_token":"\#(refresh)"}}"#
      .utf8
  )
}

private func reviewClaudePayload(access: String, refresh: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8
  )
}
