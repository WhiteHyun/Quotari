import Foundation
@testable import QuotariCore
import Testing

struct AccountSwitchPendingFailureTests {
  @Test func failedPreparationKeepsTheResolvedGrantUntilTheSlotsCommit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let service = makeService(fixture) { _ in
      throw CocoaError(.fileWriteNoPermission)
    }

    let thrown = switchError(service, targetID: fixture.target.id)

    guard case .writeFailed = thrown else {
      Issue.record("expected .writeFailed, got \(String(describing: thrown))")
      return
    }
    try expectBackedUpPendingGrant(fixture)
    try expectRawSlots(fixture)
  }

  @Test func failedFileCommitRestoresRawSlotsAndKeepsTheResolvedGrant() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let counter = PendingGrantWriteCounter()
    let service = makeCommitFailingService(fixture, counter: counter)

    let thrown = switchError(service, targetID: fixture.target.id)

    guard case .writeFailed = thrown else {
      Issue.record("expected .writeFailed, got \(String(describing: thrown))")
      return
    }
    #expect(counter.value == 2)
    try expectBackedUpPendingGrant(fixture)
    try expectRawSlots(fixture)
  }

  @Test func failedCleanupDoesNotBlockTheNextSwitchAfterTheGrantWasBackedUp() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let pendingService = "\(fixture.registryService).pending.\(fixture.pendingID)"
    fixture.registryKeychain.failDeletes(of: pendingService)
    let service = makeService(fixture)
    let second = CapturedAccount(
      id: "claude:fp-second",
      provider: .claude,
      displayName: "Second Claude",
      detail: "Keychain",
      capturedAt: Date(timeIntervalSince1970: 1),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(
        accessToken: "saved-second",
        refreshToken: "saved-second-ref",
        expiresAt: 200_000
      ),
      claudeOAuthAccount: Data(
        #"{"accountUuid":"second","emailAddress":"second@example.com"}"#.utf8
      )
    )
    try fixture.registry.save(second)

    _ = try service.switchCLI(
      toRegistryAccount: fixture.target.id,
      now: Date(timeIntervalSince1970: 5000)
    )
    let retainedData = try #require(fixture.registry.pendingGrantData(id: fixture.pendingID))
    let retained = try JSONDecoder().decode(ClaudePendingGrant.self, from: retainedData)
    #expect(retained.liveSourceBackupRecorded == true)

    _ = try service.switchCLI(
      toRegistryAccount: second.id,
      now: Date(timeIntervalSince1970: 6000)
    )

    let keychain = try ClaudeCredentialsStore.parse(#require(fixture.keychain.value))
    let file = try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL))
    #expect(keychain.accessToken == "saved-second")
    #expect(file.accessToken == "saved-second")
  }
}

private extension AccountSwitchPendingFailureTests {
  struct Fixture {
    var registry: CapturedAccountStore
    var target: CapturedAccount
    var home: URL
    var fileURL: URL
    var keychain: KeychainSlot
    var pendingID: String
    var pendingData: Data
    var rawKeychain: Data
    var rawFile: Data
    var registryKeychain: InMemoryKeychain
    var registryService: String
  }

  func makeFixture() throws -> Fixture {
    let registryKeychain = InMemoryKeychain()
    let registryService = "Test-Switch-Pending-Failure-\(UUID().uuidString)"
    let registry = CapturedAccountStore(keychain: registryKeychain.store, service: registryService)
    let target = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let (rawKeychain, rawFile) = rawSlotPayloads()
    try rawFile.write(to: fileURL)
    let keychain = KeychainSlot(rawKeychain)
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let pending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(
        accessToken: "live-b",
        refreshToken: "live-b-ref",
        expiresAt: Date(timeIntervalSince1970: 100_000)
      ),
      previousAccessToken: "live-a",
      consumedRefreshToken: "live-a-ref"
    )
    let pendingID = try #require(source.claudeLivePendingGrantID)
    let pendingData = try JSONEncoder().encode(pending)
    #expect(try registry.saveLivePendingGrantIfAbsent(pendingData, id: pendingID))
    return Fixture(
      registry: registry,
      target: target,
      home: home,
      fileURL: fileURL,
      keychain: keychain,
      pendingID: pendingID,
      pendingData: pendingData,
      rawKeychain: rawKeychain,
      rawFile: rawFile,
      registryKeychain: registryKeychain,
      registryService: registryService
    )
  }

  func makeService(
    _ fixture: Fixture,
    setOwnerOnlyPermissions: (@Sendable (URL) throws -> Void)? = nil
  ) -> AccountSwitchService {
    AccountSwitchService(
      capturedAccounts: fixture.registry,
      capture: AccountCaptureService(
        capturedAccounts: fixture.registry,
        claudeKeychainRead: { _ in fixture.keychain.value }
      ),
      environment: [:],
      home: fixture.home,
      keychainRead: { _ in fixture.keychain.value },
      keychainWrite: { data, _ in fixture.keychain.value = data },
      setOwnerOnlyPermissions: setOwnerOnlyPermissions
    )
  }

  func makeCommitFailingService(
    _ fixture: Fixture,
    counter: PendingGrantWriteCounter
  ) -> AccountSwitchService {
    let directory = fixture.fileURL.deletingLastPathComponent()
    return AccountSwitchService(
      capturedAccounts: fixture.registry,
      capture: AccountCaptureService(
        capturedAccounts: fixture.registry,
        claudeKeychainRead: { _ in fixture.keychain.value }
      ),
      environment: [:],
      home: fixture.home,
      keychainRead: { _ in fixture.keychain.value },
      keychainWrite: { data, _ in
        fixture.keychain.value = data
        guard counter.next() == 0 else { return }
        let temporaryNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
          .filter { $0.hasPrefix(".credentials.json.quotari.") }
        for name in temporaryNames {
          try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
      }
    )
  }

  func switchError(
    _ service: AccountSwitchService,
    targetID: String
  ) -> AccountSwitchError? {
    do {
      try service.switchCLI(toRegistryAccount: targetID, now: Date(timeIntervalSince1970: 5000))
      return nil
    } catch let error as AccountSwitchError {
      return error
    } catch {
      Issue.record("unexpected error: \(error)")
      return nil
    }
  }

  func expectRawSlots(_ fixture: Fixture) throws {
    let keychainData = try #require(fixture.keychain.value)
    let fileData = try Data(contentsOf: fixture.fileURL)
    let keychain = try ClaudeCredentialsStore.parse(keychainData)
    let file = try ClaudeCredentialsStore.parse(fileData)
    #expect(keychain.accessToken == "live-a")
    #expect(file.accessToken == "live-a")
    #expect(keychainData == fixture.rawKeychain)
    #expect(fileData == fixture.rawFile)
  }

  func expectBackedUpPendingGrant(_ fixture: Fixture) throws {
    let retainedData = try #require(fixture.registry.pendingGrantData(id: fixture.pendingID))
    let retained = try JSONDecoder().decode(ClaudePendingGrant.self, from: retainedData)
    var expected = try JSONDecoder().decode(ClaudePendingGrant.self, from: fixture.pendingData)
    expected.liveSourceBackupRecorded = true
    #expect(retained == expected)
  }

  func rawSlotPayloads() -> (keychain: Data, file: Data) {
    let keychain = Data(
      """
      {"claudeAiOauth":{"accessToken":"live-a","refreshToken":"live-a-ref","expiresAt":1000000},
      "keychainOnly":"kept"}
      """.utf8
    )
    let file = Data(
      """
      {"fileOnly":"kept",
      "claudeAiOauth":{"refreshToken":"live-a-ref","expiresAt":1000000,"accessToken":"live-a"}}
      """.utf8
    )
    return (keychain, file)
  }
}

private final class PendingGrantWriteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> Int {
    lock.withLock {
      defer { count += 1 }
      return count
    }
  }

  var value: Int {
    lock.withLock { count }
  }
}
