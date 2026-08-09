import Foundation
@testable import QuotariCore
import Testing

/// Switch recovery when preparing, committing, or rolling back CLI credentials fails.
struct AccountSwitchWriteFailureTests {
  @Test func claudeFilePreparationFailureLeavesTheKeychainUntouched() throws {
    // Both Claude stores exist. The replacement file cannot be prepared, so
    // the switch must fail before its first keychain mutation.
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    let claudeDir = home.appendingPathComponent(".claude")
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claudeDir.path)
      try? FileManager.default.removeItem(at: home)
    }
    let fileURL = claudeDir.appendingPathComponent(".credentials.json")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try Data(#"{"claudeAiOauth":{"accessToken":"file-tok","refreshToken":"file-ref"}}"#.utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: claudeDir.path)
    let slot = KeychainSlot(Data(#"{"claudeAiOauth":{"accessToken":"kc-tok","refreshToken":"kc-ref"}}"#.utf8))
    let writes = WriteCounter()
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in
        _ = writes.next()
        slot.value = data
      }
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    } catch let error as AccountSwitchError {
      thrown = error
    }
    guard case .writeFailed = thrown else {
      Issue.record("expected .writeFailed, got \(String(describing: thrown))")
      return
    }
    #expect(writes.value == 0)
    let live = try ClaudeCredentialsStore.parse(#require(slot.value))
    #expect(live.accessToken == "kc-tok")
    #expect(live.refreshToken == "kc-ref")
    // Both prior logins were preserved before any write. New Claude registry
    // IDs are opaque, so locate each row by its saved credential instead.
    let keychainBackup = try capturedClaudeAccount(registry: registry, refreshToken: "kc-ref")
    let fileBackup = try capturedClaudeAccount(registry: registry, refreshToken: "file-ref")
    #expect(keychainBackup.id.hasPrefix("claude:"))
    #expect(fileBackup.id.hasPrefix("claude:"))
    #expect(keychainBackup.id != fileBackup.id)
  }

  @Test func claudeCommitAndRollbackFailuresSurfaceAPartialSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let claudeDir = home.appendingPathComponent(".claude")
    let fileURL = claudeDir.appendingPathComponent(".credentials.json")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try Data(#"{"claudeAiOauth":{"accessToken":"file-tok","refreshToken":"file-ref"}}"#.utf8)
      .write(to: fileURL)
    let slot = KeychainSlot(
      Data(#"{"claudeAiOauth":{"accessToken":"kc-tok","refreshToken":"kc-ref"}}"#.utf8)
    )
    let writes = WriteCounter()
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in
        if writes.next() == 0 {
          slot.value = data
          let temporaryNames = try FileManager.default.contentsOfDirectory(atPath: claudeDir.path)
            .filter { $0.hasPrefix(".credentials.json.quotari.") }
          for name in temporaryNames {
            try FileManager.default.removeItem(at: claudeDir.appendingPathComponent(name))
          }
        } else {
          throw KeychainItemStore.KeychainError.commandFailed(status: 51)
        }
      }
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .partialSwitch = thrown else {
      Issue.record("expected .partialSwitch, got \(String(describing: thrown))")
      return
    }
    #expect(writes.value == 2)
  }
}

/// Counts keychain writes so a test can fail a specific one.
private final class WriteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int {
    lock.withLock { defer { count += 1 }; return count }
  }

  var value: Int {
    lock.withLock { count }
  }
}
