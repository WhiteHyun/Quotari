import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchPendingGrantTests {
  @Test func pendingGrantReadFailureAbortsBeforeInstallingAConsumedPair() throws {
    let keychain = InMemoryKeychain()
    let prefix = "Test-PendingRead-\(UUID().uuidString)"
    let registry = CapturedAccountStore(keychain: keychain.store, service: prefix)
    let saved = try savedCodexAccount(registry: registry)
    let pending = CodexPendingGrant(
      grant: CodexTokenGrant(accessToken: "fresh-tok", refreshToken: "fresh-ref"),
      previousAccessToken: "saved-tok",
      consumedRefreshToken: "saved-ref"
    )
    try registry.savePendingGrant(JSONEncoder().encode(pending), id: saved.id)
    keychain.failReads(of: "\(prefix).pending.\(saved.id)")
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .slotReadFailed = thrown else {
      Issue.record("expected .slotReadFailed, got \(String(describing: thrown))")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path))
  }

  @Test func codexPermissionPreparationFailureLeavesTheExistingSlotUntouched() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(#"{"tokens":{"access_token":"live-tok","account_id":"acct-live","refresh_token":"live-ref"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in },
      setOwnerOnlyPermissions: { _ in throw InjectedPermissionError() }
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(
        toRegistryAccount: saved.id,
        now: Date(timeIntervalSince1970: 5000)
      )
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .writeFailed = thrown else {
      Issue.record("expected .writeFailed, got \(String(describing: thrown))")
      return
    }
    let live = try CodexCredentialsStore.parse(Data(contentsOf: authURL))
    #expect(live.accessToken == "live-tok")
    #expect(live.refreshToken == "live-ref")
    let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let temporaryNames = try FileManager.default.contentsOfDirectory(
      atPath: authURL.deletingLastPathComponent().path
    ).filter { $0.hasPrefix(".auth.json.quotari.") }
    #expect(temporaryNames.isEmpty)
  }

  @Test func codexSwitchAppliesAndClearsAPendingRotatedGrant() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let pending = CodexPendingGrant(
      grant: CodexTokenGrant(accessToken: "fresh-tok", refreshToken: "fresh-ref"),
      previousAccessToken: "superseded-tok",
      consumedRefreshToken: "saved-ref"
    )
    try registry.savePendingGrant(JSONEncoder().encode(pending), id: saved.id)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let stored = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: saved.id), capturedAccounts: registry
    )
    #expect(stored.accessToken == "fresh-tok")
    #expect(stored.refreshToken == "fresh-ref")
    let live = try CodexCredentialsStore.parse(Data(contentsOf: home.appendingPathComponent(".codex/auth.json")))
    #expect(live.accessToken == "fresh-tok")
    #expect(live.refreshToken == "fresh-ref")
    #expect(registry.pendingGrantData(id: saved.id) == nil)
  }

  @Test func claudeSwitchAppliesAndClearsAPendingRotatedGrant() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let pending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(
        accessToken: "fresh-tok",
        refreshToken: "fresh-ref",
        expiresAt: Date(timeIntervalSince1970: 10000)
      ),
      previousAccessToken: "superseded-tok",
      consumedRefreshToken: "saved-ref"
    )
    try registry.savePendingGrant(JSONEncoder().encode(pending), id: saved.id)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = KeychainSlot()
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let stored = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: saved.id), capturedAccounts: registry
    )
    #expect(stored.accessToken == "fresh-tok")
    #expect(stored.refreshToken == "fresh-ref")
    let live = try ClaudeCredentialsStore.parse(#require(slot.value))
    #expect(live.accessToken == "fresh-tok")
    #expect(live.refreshToken == "fresh-ref")
    #expect(registry.pendingGrantData(id: saved.id) == nil)
  }
}

private struct InjectedPermissionError: Error {}
