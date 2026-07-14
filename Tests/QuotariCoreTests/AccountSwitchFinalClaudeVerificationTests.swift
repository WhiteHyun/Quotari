import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchFinalVerificationTests {
  @Test func finalFileCreationRemovesTheInstalledKeychain() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    let createdFile = finalReviewClaudePayload(access: "file-new", refresh: "file-new-ref")
    let keychain = FinalClaudeFileRotator(
      nil,
      fileURL: fileURL,
      replacement: createdFile,
      triggerReadAfterWrite: 2
    )
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { service in try? keychain.read(service) }
      ),
      environment: [:],
      home: home,
      keychainRead: keychain.read,
      keychainWrite: keychain.write,
      keychainDelete: keychain.delete
    )

    let thrown = captureFinalReviewSwitchError(service, accountID: saved.id)

    guard case .concurrentCredentialChange = thrown else {
      Issue.record("expected .concurrentCredentialChange, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == nil)
    #expect(try Data(contentsOf: fileURL) == createdFile)
  }
}

final class FinalClaudeFileRotator: @unchecked Sendable {
  private let lock = NSLock()
  private let fileURL: URL
  private let replacement: Data
  private let triggerReadAfterWrite: Int
  private var storage: Data?
  private var readsAfterWrite = 0
  private var didWrite = false

  var value: Data? {
    lock.withLock { storage }
  }

  init(
    _ value: Data?,
    fileURL: URL,
    replacement: Data,
    triggerReadAfterWrite: Int = 3
  ) {
    storage = value
    self.fileURL = fileURL
    self.replacement = replacement
    self.triggerReadAfterWrite = triggerReadAfterWrite
  }

  func read(_: String) throws -> Data? {
    try lock.withLock {
      if didWrite {
        readsAfterWrite += 1
        if readsAfterWrite == triggerReadAfterWrite {
          try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try replacement.write(to: fileURL)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
          )
        }
      }
      return storage
    }
  }

  func write(_ data: Data, _: String) {
    lock.withLock {
      storage = data
      didWrite = true
    }
  }

  func delete(_: String) {
    lock.withLock { storage = nil }
  }
}

private func captureFinalReviewSwitchError(
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

private func finalReviewClaudePayload(access: String, refresh: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8
  )
}
