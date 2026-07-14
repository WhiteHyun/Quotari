import Foundation
@testable import QuotariCore
import Testing

/// Switch edge cases: orphan avoidance, id-less backups, no stale downgrade.
struct AccountSwitchEdgeCaseTests {
  @Test func claudeFileOnlySwitchLeavesNoOrphanKeychainItemOnFileWriteFailure() throws {
    // Only the credentials file exists (no keychain item). A failed file
    // write must not leave a newly-created keychain item behind — the switch
    // writes only the store the user was actually using.
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
    let slot = KeychainSlot(nil) // no keychain item
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    #expect(throws: AccountSwitchError.self) {
      try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    }

    // No keychain item was ever created for a keychain the user didn't have.
    #expect(slot.value == nil)
  }

  @Test func codexSwitchBacksUpARenewableLoginWithoutAnAccountID() throws {
    // A renewable Codex login with no account_id/email must still be backed
    // up (under a UUID, like normal Save) before the slot is overwritten.
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(#"{"tokens":{"access_token":"idless-tok","refresh_token":"idless-ref"}}"#.utf8).write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    // The idless login was preserved (a codex: UUID entry beyond the saved one).
    let backups = registry.load().filter { $0.provider == .codex && $0.id != "codex:acct-saved" }
    #expect(backups.count == 1)
    let restored = try CodexCredentialsStore.parse(#require(backups.first).payload)
    #expect(restored.accessToken == "idless-tok")
    #expect(restored.refreshToken == "idless-ref")
  }

  @Test func backingUpAStaleSlotNeverDowngradesAFresherSavedCopy() throws {
    // The registry already holds a FRESH copy of an identity; backing up a
    // STALE duplicate slot of that identity must not downgrade it.
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let fresh = codexJWT(claims: ["exp": 100_000])
    let stale = codexJWT(claims: ["exp": 1000])
    try registry.save(CapturedAccount(
      id: "codex:acct-dup",
      provider: .codex,
      displayName: "Dup",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: "/tmp/fresh.json"),
      payload: Data(#"{"tokens":{"access_token":"\#(fresh)","account_id":"acct-dup","refresh_token":"fresh-ref"}}"#
        .utf8)
    ))
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // The live slot is a STALE duplicate of acct-dup.
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(#"{"tokens":{"access_token":"\#(stale)","account_id":"acct-dup","refresh_token":"stale-ref"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    // The fresher saved pair survived the stale-slot backup.
    let kept = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-dup"), capturedAccounts: registry
    )
    #expect(kept.accessToken == fresh)
    #expect(kept.refreshToken == "fresh-ref")
  }

  @Test func switchReadsTheClaudeKeychainByServiceOnly() throws {
    // The default keychain read must match discovery (service-only, no
    // account filter), or a Claude item under a non-default account attribute
    // would be missed. We assert the default closure calls readByService by
    // observing the service it's asked for.
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = KeychainSlot(Data(#"{"claudeAiOauth":{"accessToken":"live","refreshToken":"live-ref"}}"#.utf8))
    let requested = RequestedService()
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { svc in requested.record(svc); return slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    #expect(requested.value == "Claude Code-credentials")
    let stored = try JSONSerialization.jsonObject(with: #require(slot.value)) as? [String: Any]
    #expect((stored?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "saved-tok")
  }

  @Test func switchUsesTheFreshestTargetPayloadAfterBackup() throws {
    // Switching TO an account that is ALSO the current live slot, which has
    // rotated since the saved row was captured: the backup refreshes the
    // target's registry id to the live pair, and the transplant must use that
    // fresher payload, not the stale saved one.
    let registry = makeSwitchRegistry()
    // Saved target with an OLD token.
    try registry.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Target",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: "/tmp/t.json"),
      payload: Data(#"{"tokens":{"access_token":"old-tok","account_id":"acct-1","refresh_token":"old-ref"}}"#.utf8)
    ))
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    try FileManager.default.createDirectory(
      at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // The live slot is the SAME identity with a NEWER pair.
    try Data(#"{"tokens":{"access_token":"new-tok","account_id":"acct-1","refresh_token":"new-ref"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    try service.switchCLI(toRegistryAccount: "codex:acct-1", now: Date(timeIntervalSince1970: 5000))

    // The slot keeps the fresher live pair, not the stale saved one.
    let slot = try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
    #expect((slot?["tokens"] as? [String: Any])?["access_token"] as? String == "new-tok")
  }
}

/// Switch recovery for post-write failures, pending rotations, and identity trust.
struct AccountSwitchRecoveryTests {
  @Test func verifiedRotatedClaudeTargetRefreshesItsSavedRowInPlace() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let serviceName = ClaudeCredentialsStore.keychainService
    let slot = KeychainSlot(Data(
      // The provider may shorten a rotated token's expiry. Independent
      // source+generation proof, not expiry ordering, owns this update.
      #"{"claudeAiOauth":{"accessToken":"rotated-tok","refreshToken":"rotated-ref","expiresAt":8000000000000}}"#.utf8
    ))
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    try service.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 5000),
      knownLiveTarget: KnownLiveClaudeTarget(
        source: .claudeKeychain(service: serviceName),
        accessTokenFingerprint: ProviderCredentialIdentity.fingerprint(of: "rotated-tok")
      )
    )

    let claudeAccounts = registry.load().filter { $0.provider == .claude }
    #expect(claudeAccounts.map(\.id) == [saved.id])
    let stored = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: saved.id), capturedAccounts: registry
    )
    #expect(stored.accessToken == "rotated-tok")
    #expect(stored.refreshToken == "rotated-ref")
    let live = try ClaudeCredentialsStore.parse(#require(slot.value))
    #expect(live.accessToken == "rotated-tok")
    #expect(live.refreshToken == "rotated-ref")
  }

  @Test func reloginBeforeTheSecondReadCannotOverwriteTheVerifiedTarget() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let serviceName = ClaudeCredentialsStore.keychainService
    let verified = Data(
      #"{"claudeAiOauth":{"accessToken":"rotated-tok","refreshToken":"rotated-ref","expiresAt":8000000000000}}"#.utf8
    )
    let reloggedIn = Data(
      #"{"claudeAiOauth":{"accessToken":"other-tok","refreshToken":"other-ref","expiresAt":9000000000000}}"#.utf8
    )
    let reads = KeychainReadSequence([verified, reloggedIn])
    let written = KeychainSlot()
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in reads.next() },
      keychainWrite: { data, _ in
        reads.write(data)
        written.value = data
      }
    )

    try service.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 5000),
      knownLiveTarget: KnownLiveClaudeTarget(
        source: .claudeKeychain(service: serviceName),
        accessTokenFingerprint: ProviderCredentialIdentity.fingerprint(of: "rotated-tok")
      )
    )

    let target = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: saved.id), capturedAccounts: registry
    )
    #expect(target.accessToken == "rotated-tok")
    #expect(target.refreshToken == "rotated-ref")
    let backup = try #require(registry.load().first { account in
      account.provider == .claude && account.id != saved.id
    })
    let backupCredentials = try ClaudeCredentialsStore.parse(backup.payload)
    #expect(backupCredentials.accessToken == "other-tok")
    #expect(backupCredentials.refreshToken == "other-ref")
    let live = try ClaudeCredentialsStore.parse(#require(written.value))
    #expect(live.accessToken == "rotated-tok")
  }

  @Test func unverifiedRotatedClaudeLoginDoesNotOverwriteTheTargetRow() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = KeychainSlot(Data(
      #"{"claudeAiOauth":{"accessToken":"other-tok","refreshToken":"other-ref","expiresAt":10000000000000}}"#.utf8
    ))
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      environment: [:],
      home: home,
      keychainRead: { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data }
    )

    try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))

    let target = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: saved.id), capturedAccounts: registry
    )
    #expect(target.accessToken == "saved-tok")
    #expect(target.refreshToken == "saved-ref")
    let backup = try #require(registry.load().first { account in
      account.provider == .claude && account.id != saved.id
    })
    let backupCredentials = try ClaudeCredentialsStore.parse(backup.payload)
    #expect(backupCredentials.accessToken == "other-tok")
    #expect(backupCredentials.refreshToken == "other-ref")
    let live = try ClaudeCredentialsStore.parse(#require(slot.value))
    #expect(live.accessToken == "saved-tok")
    #expect(live.refreshToken == "saved-ref")
  }

  @Test func codexSwitchAbortsWhenTheCurrentSlotIsWorldReadable() throws {
    // The switch must honor the same permission policy as capture: refuse to
    // snapshot a group/world-readable Codex token file, failing closed with
    // the slot untouched.
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
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authURL.path)
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in nil }),
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in }
    )

    #expect(throws: AccountSwitchError.self) {
      try service.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 5000))
    }

    // Slot untouched — still the live account.
    let slot = try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
    #expect((slot?["tokens"] as? [String: Any])?["account_id"] as? String == "acct-live")
  }
}

/// Records the last keychain service a switch asked to read.
private final class RequestedService: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String?
  func record(_ service: String) {
    lock.withLock { storage = service }
  }

  var value: String? {
    lock.withLock { storage }
  }
}

private final class KeychainReadSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let values: [Data]
  private var index = 0
  private var written: Data?

  init(_ values: [Data]) {
    self.values = values
  }

  func next() -> Data? {
    lock.withLock {
      if let written {
        return written
      }
      guard !values.isEmpty else { return nil }
      defer { index += 1 }
      return values[min(index, values.count - 1)]
    }
  }

  func write(_ data: Data) {
    lock.withLock { written = data }
  }
}
