import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchLivePendingGrantTests {
  @Test func switchBacksUpTheRotatedGrantInsteadOfItsConsumedMirrors() throws {
    let registry = makeSwitchRegistry()
    let target = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let consumed = claudePayload(
      accessToken: "live-a",
      refreshToken: "live-a-ref",
      expiresAt: 1000
    )
    try consumed.write(to: fileURL)
    let keychain = KeychainSlot(consumed)
    let keychainSource = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let pending = rotatedGrant(previous: "live-a", consumed: "live-a-ref")
    let pendingID = try #require(keychainSource.claudeLivePendingGrantID)
    #expect(try registry.saveLivePendingGrantIfAbsent(JSONEncoder().encode(pending), id: pendingID))
    let service = makeService(registry: registry, home: home, keychain: keychain)

    try service.switchCLI(toRegistryAccount: target.id, now: Date(timeIntervalSince1970: 5000))

    let backups = try registry.load()
      .filter { $0.provider == .claude && $0.id != target.id }
      .map { try ClaudeCredentialsStore.parse($0.payload) }
    #expect(backups.count == 1)
    #expect(backups.first?.accessToken == "live-b")
    #expect(backups.first?.refreshToken == "live-b-ref")
    #expect(!backups.contains { $0.accessToken == "live-a" })
    #expect(registry.pendingGrantData(id: pendingID) == nil)
    let liveKeychain = try ClaudeCredentialsStore.parse(#require(keychain.value))
    let liveFile = try ClaudeCredentialsStore.parse(Data(contentsOf: fileURL))
    #expect(liveKeychain.accessToken == "saved-tok")
    #expect(liveFile.accessToken == "saved-tok")
  }

  @Test func fileOwnedGrantCarriesVerifiedTargetLineageAcrossBothMirrors() throws {
    let registry = makeSwitchRegistry()
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let consumed = claudePayload(
      accessToken: "live-a",
      refreshToken: "live-a-ref",
      expiresAt: 1000
    )
    let slots = try mirroredClaudeSlots(home: home, payload: consumed)
    let target = try verifiedTarget(
      registry: registry,
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: consumed
    )
    let fileSource = ProviderCredentialSource.claudeCredentialsFile(
      path: slots.fileURL.standardizedFileURL.path
    )
    let pending = rotatedGrant(previous: "live-a", consumed: "live-a-ref")
    let pendingID = try #require(fileSource.claudeLivePendingGrantID)
    #expect(try registry.saveLivePendingGrantIfAbsent(JSONEncoder().encode(pending), id: pendingID))
    let service = makeService(registry: registry, home: home, keychain: slots.keychain)

    try service.switchCLI(
      toRegistryAccount: target.id,
      now: Date(timeIntervalSince1970: 5000),
      knownLiveTarget: KnownLiveClaudeTarget(
        source: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        accessTokenFingerprint: ProviderCredentialIdentity.fingerprint(of: "live-a")
      )
    )

    let accounts = registry.load().filter { $0.provider == .claude }
    #expect(accounts.map(\.id) == [target.id])
    let stored = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: target.id),
      capturedAccounts: registry
    )
    #expect(stored.accessToken == "live-b")
    #expect(stored.refreshToken == "live-b-ref")
    try expectLiveAccessToken("live-b", keychain: slots.keychain, fileURL: slots.fileURL)
    #expect(registry.pendingGrantData(id: pendingID) == nil)
  }

  @Test func verifiedFileTargetIsBackedUpBeforeItsMatchingKeychainMirror() throws {
    let registry = makeSwitchRegistry()
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let consumed = claudePayload(
      accessToken: "live-a",
      refreshToken: "live-a-ref",
      expiresAt: 1000
    )
    let slots = try mirroredClaudeSlots(home: home, payload: consumed)
    let fileSource = ProviderCredentialSource.claudeCredentialsFile(
      path: slots.fileURL.standardizedFileURL.path
    )
    let target = try verifiedTarget(
      registry: registry,
      origin: fileSource,
      payload: consumed
    )
    let keychainSource = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let pending = rotatedGrant(previous: "live-a", consumed: "live-a-ref")
    let pendingID = try #require(keychainSource.claudeLivePendingGrantID)
    #expect(try registry.saveLivePendingGrantIfAbsent(JSONEncoder().encode(pending), id: pendingID))
    let service = makeService(registry: registry, home: home, keychain: slots.keychain)

    try service.switchCLI(
      toRegistryAccount: target.id,
      now: Date(timeIntervalSince1970: 5000),
      knownLiveTarget: KnownLiveClaudeTarget(
        source: fileSource,
        accessTokenFingerprint: ProviderCredentialIdentity.fingerprint(of: "live-a")
      )
    )

    let accounts = registry.load().filter { $0.provider == .claude }
    #expect(accounts.map(\.id) == [target.id])
    let stored = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: target.id),
      capturedAccounts: registry
    )
    #expect(stored.accessToken == "live-b")
    #expect(stored.refreshToken == "live-b-ref")
    try expectLiveAccessToken("live-b", keychain: slots.keychain, fileURL: slots.fileURL)
    #expect(registry.pendingGrantData(id: pendingID) == nil)
  }

  @Test func unrelatedReloginAbortsWithoutDiscardingItsPendingGrant() throws {
    let registry = makeSwitchRegistry()
    let target = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let keychain = KeychainSlot(claudePayload(
      accessToken: "unrelated-c",
      refreshToken: "unrelated-c-ref",
      expiresAt: 100_000
    ))
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let pending = rotatedGrant(previous: "live-a", consumed: "live-a-ref")
    let pendingID = try #require(source.claudeLivePendingGrantID)
    let pendingData = try JSONEncoder().encode(pending)
    #expect(try registry.saveLivePendingGrantIfAbsent(pendingData, id: pendingID))
    let service = makeService(registry: registry, home: home, keychain: keychain)

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: target.id, now: Date(timeIntervalSince1970: 5000))
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .backupFailed = thrown else {
      Issue.record("expected .backupFailed, got \(String(describing: thrown))")
      return
    }
    let live = try ClaudeCredentialsStore.parse(#require(keychain.value))
    #expect(live.accessToken == "unrelated-c")
    #expect(registry.pendingGrantData(id: pendingID) == pendingData)
    #expect(registry.load().filter { $0.provider == .claude }.map(\.id) == [target.id])
  }
}

private extension AccountSwitchLivePendingGrantTests {
  func mirroredClaudeSlots(
    home: URL,
    payload: Data
  ) throws -> (fileURL: URL, keychain: KeychainSlot) {
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try payload.write(to: fileURL)
    return (fileURL, KeychainSlot(payload))
  }

  func verifiedTarget(
    registry: CapturedAccountStore,
    origin: ProviderCredentialSource,
    payload: Data
  ) throws -> CapturedAccount {
    let target = CapturedAccount(
      id: "claude:verified-target",
      provider: .claude,
      displayName: "Verified",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: origin,
      payload: payload
    )
    try registry.save(target)
    return target
  }

  func expectLiveAccessToken(
    _ expected: String,
    keychain: KeychainSlot,
    fileURL: URL
  ) throws {
    let liveKeychain = try ClaudeCredentialsStore.parse(#require(keychain.value))
    let liveFile = try ClaudeCredentialsStore.parse(Data(contentsOf: fileURL))
    #expect(liveKeychain.accessToken == expected)
    #expect(liveFile.accessToken == expected)
  }

  func rotatedGrant(previous: String, consumed: String) -> ClaudePendingGrant {
    ClaudePendingGrant(
      grant: ClaudeTokenGrant(
        accessToken: "live-b",
        refreshToken: "live-b-ref",
        expiresAt: Date(timeIntervalSince1970: 100_000)
      ),
      previousAccessToken: previous,
      consumedRefreshToken: consumed
    )
  }

  func makeService(
    registry: CapturedAccountStore,
    home: URL,
    keychain: KeychainSlot
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
      keychainWrite: { data, _ in keychain.value = data }
    )
  }
}
