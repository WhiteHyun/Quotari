import Foundation
@testable import QuotariCore
import Testing

struct CLIActivityDetectorTests {
  @Test func matchesProviderExecutablesAndInterpreterScripts() throws {
    let detector = CLIActivityDetector(processList: {
      """
        10 /opt/homebrew/bin/codex
        11 /Applications/CodexBar.app/Contents/MacOS/CodexBar
        12 /Users/test/.local/bin/claude
        13 /Applications/Codex (Service).app/Contents/MacOS/Codex (Service)
        14 /opt/homebrew/bin/node /Users/test/.npm/bin/codex --quiet
        15 /bin/bash /Users/test/.local/bin/claude --continue
        16 /opt/homebrew/bin/node /Users/test/tool.js codex
        17 /usr/bin/rg claude
      """
    })

    #expect(try detector.activeProcesses(for: .codex) == ["codex (PID 10)", "codex (PID 14)"])
    #expect(try detector.activeProcesses(for: .claude) == ["claude (PID 12)", "claude (PID 15)"])
  }
}

struct AccountSwitchConcurrencyInterlockTests {
  @Test func activeCLIAbortsBeforeReadingOrWritingTheSlot() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    let original = codexPayload(account: "acct-live", token: "live", refresh: "live-ref")
    try writeSecureCredential(original, to: authURL)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      environment: [:],
      home: home,
      activeCLIProcesses: { _ in ["codex (PID 42)"] }
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .cliStillRunning = thrown else {
      Issue.record("expected .cliStillRunning, got \(String(describing: thrown))")
      return
    }
    #expect(try Data(contentsOf: authURL) == original)
    #expect(registry.load().count == 1)
  }

  @Test func codexFileRotationAfterTheLastSnapshotIsNotOverwritten() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    let original = codexPayload(account: "acct-live", token: "live", refresh: "live-ref")
    let rotated = codexPayload(account: "acct-live", token: "rotated", refresh: "rotated-ref")
    try writeSecureCredential(original, to: authURL)
    let interlock = ActivityInterlock(check: 3) {
      try writeSecureCredential(rotated, to: authURL)
    }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      environment: [:],
      home: home,
      activeCLIProcesses: interlock.inspect
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .concurrentCredentialChange = thrown else {
      Issue.record("expected .concurrentCredentialChange, got \(String(describing: thrown))")
      return
    }
    #expect(try Data(contentsOf: authURL) == rotated)
  }

  @Test func claudeFileRotationBetweenPhysicalWritesIsNotOverwritten() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    let original = claudePayload(access: "live", refresh: "live-ref")
    let rotated = claudePayload(access: "rotated", refresh: "rotated-ref")
    try writeSecureCredential(original, to: fileURL)
    let keychain = KeychainSlot(original)
    let interlock = ActivityInterlock(check: 3) {
      try writeSecureCredential(rotated, to: fileURL)
    }
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

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .concurrentCredentialChange = thrown else {
      Issue.record("expected .concurrentCredentialChange, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == original)
    #expect(try Data(contentsOf: fileURL) == rotated)
  }

  @Test func codexFinalVerificationNeverOverwritesANewerKeyringGeneration() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let codexDirectory = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    try Data("cli_auth_credentials_store = \"keyring\"\n".utf8)
      .write(to: codexDirectory.appendingPathComponent("config.toml"))
    let authURL = codexDirectory.appendingPathComponent("auth.json")
    let fallback = codexPayload(account: "acct-file", token: "file", refresh: "file-ref")
    try writeSecureCredential(fallback, to: authURL)
    let keyringOriginal = codexPayload(account: "acct-key", token: "key", refresh: "key-ref")
    let keyringRotated = codexPayload(account: "acct-key", token: "key-new", refresh: "key-new-ref")
    #expect(try CodexCredentialsStore.parse(keyringOriginal).accessToken == "key")
    #expect(try CodexCredentialsStore.parse(keyringRotated).accessToken == "key-new")
    let keychain = CodexKeychainSlot(keyringOriginal)
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: keychain.read)
    #expect(try storage.snapshot().payload == keyringOriginal)
    let interlock = ActivityInterlock(check: 5) {
      try keychain.write(keyringRotated, service: "Codex Auth", account: "test")
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

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .partialSwitch = thrown else {
      Issue.record(
        "expected .partialSwitch after \(interlock.count) checks, got \(String(describing: thrown))"
      )
      return
    }
    #expect(keychain.value == keyringRotated)
    #expect(try Data(contentsOf: authURL) == fallback)
  }
}

private final class ActivityInterlock: @unchecked Sendable {
  private let lock = NSLock()
  private let targetCheck: Int
  private let action: @Sendable () throws -> Void
  private var checkCount = 0

  var count: Int {
    lock.withLock { checkCount }
  }

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

private func writeSecureCredential(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func codexPayload(account: String, token: String, refresh: String) -> Data {
  let idToken = "e30.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.sig"
  return Data(
    #"{"tokens":{"id_token":"\#(idToken)","access_token":"\#(token)","account_id":"\#(account)","refresh_token":"\#(refresh)"}}"#
      .utf8
  )
}

private func claudePayload(access: String, refresh: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8
  )
}
