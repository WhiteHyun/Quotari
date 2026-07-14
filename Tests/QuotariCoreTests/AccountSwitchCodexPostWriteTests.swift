import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchCodexPostWriteTests {
  @Test func codexFileReadFailureAfterCommitIsPartial() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(
      #"{"tokens":{"access_token":"live","account_id":"acct-live","refresh_token":"live-ref"}}"#.utf8
    ).write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let reader = FailingCredentialFileReader(failOnRead: 2)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      environment: [:],
      home: home,
      fileRead: reader.read
    )

    let thrown = capturePostWriteError(service, accountID: saved.id)

    guard case .partialSwitch = thrown else {
      Issue.record("expected .partialSwitch, got \(String(describing: thrown))")
      return
    }
    #expect(try CodexCredentialsStore.load(url: authURL).accountID == "acct-saved")
  }

  @Test func codexAutoSwitchDoesNotReactivateAStaleFallbackWhenKeyringDisappears() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try postWriteCodexHome(mode: "auto")
    defer { try? FileManager.default.removeItem(at: home) }
    let keychain = CodexKeychainSlot(
      postWriteCodexPayload(account: "acct-key", token: "key", refresh: "key-ref")
    )
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: keychain.read)
    try writePostWriteCredential(
      postWriteCodexPayload(account: "acct-file", token: "file", refresh: "file-ref"),
      to: storage.authFileURL
    )
    let service = postWriteCodexService(registry: registry, home: home, keychain: keychain)

    try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    keychain.delete(service: CodexAuthStorage.keychainService, account: storage.keychainAccount)
    let fallbackSnapshot = try storage.snapshot()

    #expect(fallbackSnapshot.keyringState == .missing)
    #expect(fallbackSnapshot.payload == nil)
    #expect(!FileManager.default.fileExists(atPath: storage.authFileURL.path))
  }

  @Test func codexKeyringWriteFailureRestoresTheQuarantinedFallback() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try postWriteCodexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let originalKeyring = postWriteCodexPayload(account: "acct-key", token: "key", refresh: "key-ref")
    let fallback = postWriteCodexPayload(account: "acct-file", token: "file", refresh: "file-ref")
    let keychain = CodexKeychainSlot(originalKeyring)
    keychain.failsWrites = true
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: keychain.read)
    try writePostWriteCredential(fallback, to: storage.authFileURL)
    let service = postWriteCodexService(registry: registry, home: home, keychain: keychain)

    #expect(throws: AccountSwitchError.self) {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    }

    #expect(keychain.value == originalKeyring)
    #expect(try Data(contentsOf: storage.authFileURL) == fallback)
  }

  @Test func codexReplacementBackupFailureCleansTheQuarantinedFallback() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try postWriteCodexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let originalKeyring = postWriteCodexPayload(account: "acct-key", token: "key", refresh: "key-ref")
    let fallback = postWriteCodexPayload(account: "acct-file", token: "file", refresh: "file-ref")
    let replacement = Data(#"{"tokens":{"access_token":"rotated","account_id":"acct-rotated"}}"#.utf8)
    let keychain = CodexKeychainSlot(originalKeyring)
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: keychain.read)
    try writePostWriteCredential(fallback, to: storage.authFileURL)
    let reader = CodexFallbackReplacementReader(
      authURL: storage.authFileURL,
      replacement: replacement
    )
    let service = AccountSwitchService(
      capturedAccounts: registry,
      environment: [:],
      home: home,
      codexKeychainRead: keychain.read,
      codexKeychainWrite: keychain.write,
      codexKeychainDelete: { service, account in
        keychain.delete(service: service, account: account)
      },
      fileRead: reader.read
    )

    let thrown = capturePostWriteError(service, accountID: saved.id)

    guard case .backupFailed = thrown else {
      Issue.record("expected .backupFailed, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == originalKeyring)
    #expect(try Data(contentsOf: storage.authFileURL) == replacement)
    let quarantines = try FileManager.default.contentsOfDirectory(
      at: storage.authFileURL.deletingLastPathComponent(),
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".auth.json.quotari-quarantine.") }
    #expect(quarantines.isEmpty)
  }
}

private func postWriteCodexService(
  registry: CapturedAccountStore,
  home: URL,
  keychain: CodexKeychainSlot
) -> AccountSwitchService {
  AccountSwitchService(
    capturedAccounts: registry,
    environment: [:],
    home: home,
    codexKeychainRead: keychain.read,
    codexKeychainWrite: keychain.write,
    codexKeychainDelete: { service, account in
      keychain.delete(service: service, account: account)
    }
  )
}

private func postWriteCodexHome(mode: String) throws -> URL {
  let home = try switchTemporaryHome()
  let codexDirectory = home.appendingPathComponent(".codex")
  try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
  try Data("cli_auth_credentials_store = \"\(mode)\"\n".utf8)
    .write(to: codexDirectory.appendingPathComponent("config.toml"))
  return home
}

private func writePostWriteCredential(_ data: Data, to url: URL) throws {
  try data.write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func postWriteCodexPayload(account: String, token: String, refresh: String) -> Data {
  let idToken = "e30.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.sig"
  return Data(
    #"{"tokens":{"id_token":"\#(idToken)","access_token":"\#(token)","account_id":"\#(account)","refresh_token":"\#(refresh)"}}"#
      .utf8
  )
}

private func capturePostWriteError(
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

private final class FailingCredentialFileReader: @unchecked Sendable {
  private let lock = NSLock()
  private let failOnRead: Int
  private var readCount = 0

  init(failOnRead: Int) {
    self.failOnRead = failOnRead
  }

  func read(_ url: URL) throws -> Data? {
    let shouldFail = lock.withLock {
      readCount += 1
      return readCount == failOnRead
    }
    if shouldFail {
      throw CocoaError(.fileReadUnknown)
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }
}

private final class CodexFallbackReplacementReader: @unchecked Sendable {
  private let lock = NSLock()
  private let authURL: URL
  private let replacement: Data
  private var didReplace = false

  init(authURL: URL, replacement: Data) {
    self.authURL = authURL
    self.replacement = replacement
  }

  func read(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let shouldReplace = lock.withLock {
      guard !didReplace,
            url.lastPathComponent.hasPrefix(".auth.json.quotari-quarantine.")
      else { return false }
      didReplace = true
      return true
    }
    if shouldReplace {
      try writePostWriteCredential(replacement, to: authURL)
    }
    return data
  }
}
