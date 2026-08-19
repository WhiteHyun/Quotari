import CustomDump
import Foundation
@testable import QuotariCore
import Testing

struct CredentialLifecycleLogStoreTests {
  @Test func writesOnlyOpaqueAccountIdentityWithOwnerOnlyPermissions() throws {
    let fixture = try CredentialLifecycleLogFixture()
    defer { fixture.remove() }
    let rawPath = "/Users/alice/.codex/auth.json"
    let account = ProviderAccount(
      provider: .codex,
      displayName: "alice@example.com",
      detail: "Personal account",
      credentialSource: .codexAuthFile(path: rawPath),
      credentialIdentity: "secret-access-token"
    )
    let logger = CredentialLifecycleLogger(
      record: { try? fixture.store.record($0) },
      opaqueAccountID: { fixture.store.opaqueIdentifier(for: $0) },
      now: { fixture.now }
    )

    logger.record(.validationStarted, provider: .codex, account: account, interaction: .background)

    let raw = try String(contentsOf: fixture.url, encoding: .utf8)
    #expect(!raw.contains(rawPath))
    #expect(!raw.contains("alice@example.com"))
    #expect(!raw.contains("secret-access-token"))
    #expect(!raw.contains(account.id))
    let event = try #require(fixture.store.events().first)
    #expect(event.accountID?.count == 32)
    expectNoDifference(event.source, .codexFile)
    expectNoDifference(event.kind, .validationStarted)

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
    expectNoDifference((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  @Test func removesExpiredEventsAndKeepsMalformedLinesOut() throws {
    let fixture = try CredentialLifecycleLogFixture()
    defer { fixture.remove() }
    let old = fixture.event(at: fixture.now.addingTimeInterval(-22 * 24 * 60 * 60))
    let current = fixture.event(at: fixture.now)

    try fixture.store.record(old)
    let handle = try FileHandle(forWritingTo: fixture.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("not-json\n".utf8))
    try handle.close()
    try fixture.store.record(current)

    try expectNoDifference(fixture.store.events(), [current])
  }

  @Test func preservesANewEventAfterAPartialTrailingRecord() throws {
    let fixture = try CredentialLifecycleLogFixture()
    defer { fixture.remove() }
    let current = fixture.event(at: fixture.now)
    let url = try fixture.store.prepareLogForAccess()
    try Data(#"{"schemaVersion":"#.utf8).write(to: url)

    try fixture.store.record(current)

    try expectNoDifference(fixture.store.events(), [current])
    #expect(try Data(contentsOf: url).split(separator: 0x0A).count == 2)
  }

  @Test func boundsTheFileByDroppingTheOldestCompleteEvents() throws {
    let fixture = try CredentialLifecycleLogFixture(maximumByteCount: 700)
    defer { fixture.remove() }
    let events = (0 ..< 20).map {
      fixture.event(at: fixture.now.addingTimeInterval(TimeInterval($0)))
    }

    for event in events {
      try fixture.store.record(event)
    }

    let data = try Data(contentsOf: fixture.url)
    #expect(data.count <= 700)
    let retained = try fixture.store.events()
    #expect(!retained.isEmpty)
    expectNoDifference(retained.last, events.last)
    #expect(retained.count < events.count)
  }

  @Test func prunesExpiredEventsWithoutWaitingForAnotherLifecycleEvent() throws {
    let fixture = try CredentialLifecycleLogFixture()
    defer { fixture.remove() }
    try fixture.store.record(fixture.event(at: fixture.now))

    fixture.advance(by: 22 * 24 * 60 * 60)
    try fixture.store.performMaintenance()

    try expectNoDifference(fixture.store.events(), [])
  }

  @Test func materializesAnOwnerOnlyEmptyLogForAccess() throws {
    let fixture = try CredentialLifecycleLogFixture()
    defer { fixture.remove() }

    let url = try fixture.store.prepareLogForAccess()

    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url).isEmpty)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
    expectNoDifference((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    expectNoDifference((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }

  @Test func compactsBelowTheLimitSoTheNextEventCanAppendWithoutARewrite() throws {
    let fixture = try CredentialLifecycleLogFixture(maximumByteCount: 2000)
    defer { fixture.remove() }
    var previousByteCount = 0
    var observedCompaction = false

    for offset in 0 ..< 100 {
      try fixture.store.record(fixture.event(at: fixture.now.addingTimeInterval(TimeInterval(offset))))
      let byteCount = try Data(contentsOf: fixture.url).count
      if byteCount < previousByteCount {
        observedCompaction = true
        let retainedCount = try fixture.store.events().count
        let sizeAfterCompaction = byteCount

        try fixture.store.record(fixture.event(at: fixture.now.addingTimeInterval(200)))

        #expect(try fixture.store.events().count == retainedCount + 1)
        #expect(try Data(contentsOf: fixture.url).count > sizeAfterCompaction)
        break
      }
      previousByteCount = byteCount
    }

    #expect(observedCompaction)
  }

  @Test func opaqueIdentifiersAreStablePerSaltAndDifferentAcrossSalts() throws {
    let first = try CredentialLifecycleLogFixture(identitySalt: Data("first-install".utf8))
    let second = try CredentialLifecycleLogFixture(identitySalt: Data("second-install".utf8))
    defer {
      first.remove()
      second.remove()
    }

    let firstID = first.store.opaqueIdentifier(for: "raw-account-id")
    expectNoDifference(first.store.opaqueIdentifier(for: "raw-account-id"), firstID)
    #expect(second.store.opaqueIdentifier(for: "raw-account-id") != firstID)
    #expect(!firstID.contains("raw-account-id"))
  }

  @Test func protectsTheGeneratedSaltAndDiagnosticsDirectory() throws {
    let fixture = try CredentialLifecycleLogFixture(identitySalt: nil)
    defer { fixture.remove() }

    _ = fixture.store.opaqueIdentifier(for: "raw-account-id")

    let saltAttributes = try FileManager.default.attributesOfItem(atPath: fixture.store.saltURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
    expectNoDifference((saltAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    expectNoDifference((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }
}

struct CredentialLifecycleFailureTests {
  @Test func classifiesURLSessionCancellationAsCancelled() {
    expectNoDifference(
      CredentialLifecycleEvent.Failure.classify(URLError(.cancelled)),
      .cancelled
    )
  }
}

struct CredentialLifecycleRefreshTests {
  @Test func codexRefreshRecordsSelectionExchangeAndPersistence() async throws {
    let recorder = CredentialLifecycleEventRecorder()
    let expired = codexJWT(claims: ["exp": 1000])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: expired, refreshToken: "ref-1")
    )
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON),
      refresher: StubCodexRefresher(
        result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
      ),
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator(),
      credentialLifecycleLogger: recorder.logger
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    expectNoDifference(recorder.events.map(\.kind), [
      .refreshSelected,
      .refreshStarted,
      .refreshSucceeded,
      .persistenceSucceeded,
    ])
    #expect(recorder.events.allSatisfy { $0.accountID == "opaque-test-account" })
  }

  @Test func claudeLinkedInvalidGrantUsesTheSavedAccountCorrelationWithoutRecordingErrorText() async throws {
    let recorder = CredentialLifecycleEventRecorder(opaqueAccountID: { "opaque:\($0)" })
    let liveDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-linked-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: liveDirectory) }
    let liveURL = liveDirectory.appendingPathComponent(".credentials.json")
    let expiredCredentials = ClaudeCredentials(
      accessToken: "expired-access-token",
      refreshToken: "expired-refresh-token",
      expiresAt: Date(timeIntervalSince1970: 1000)
    )
    let capturedAccounts = try makeClaudeRegistryStore(
      payload: claudePayload(
        accessToken: "expired-access-token",
        refreshToken: "expired-refresh-token",
        expiresAt: 1000
      )
    )
    try claudePayload(
      accessToken: "expired-access-token",
      refreshToken: "expired-refresh-token",
      expiresAt: 1000
    ).write(to: liveURL)
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: "{}", status: 401),
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: expiredCredentials,
          source: .claudeCredentialsFile(path: liveURL.path)
        )
      },
      reloadCredentials: { _ in expiredCredentials },
      refresher: StubRefresher(result: .failure(ClaudeTokenRefreshError.reauthenticationRequired)),
      persister: RecordingPersister(),
      capturedAccounts: capturedAccounts,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      credentialLifecycleLogger: recorder.logger
    )

    await #expect(throws: ClaudeTokenRefreshError.self) {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: Date(timeIntervalSince1970: 2000),
        capturedRegistryID: "claude:fp-1"
      ))
    }

    let failures = recorder.events.filter { $0.kind == .refreshFailed }
    expectNoDifference(failures.map(\.failure), [
      .reauthenticationRequired,
    ])
    expectLinkedClaudeCorrelation(failures)
  }
}

private func expectLinkedClaudeCorrelation(_ events: [CredentialLifecycleEvent]) {
  let savedSource = ProviderCredentialSource.quotariRegistry(id: "claude:fp-1")
  let savedAccountID = ProviderAccount.id(provider: .claude, source: savedSource)
  #expect(events.allSatisfy { $0.accountID == "opaque:\(savedAccountID)" })
  #expect(events.allSatisfy { $0.source == .claudeFile })
}

final class CredentialLifecycleEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CredentialLifecycleEvent] = []
  private let opaqueAccountID: @Sendable (String) -> String

  init(
    opaqueAccountID: @escaping @Sendable (String) -> String = { _ in "opaque-test-account" }
  ) {
    self.opaqueAccountID = opaqueAccountID
  }

  var events: [CredentialLifecycleEvent] {
    lock.withLock { storage }
  }

  var logger: CredentialLifecycleLogger {
    CredentialLifecycleLogger(
      record: { [weak self] event in
        guard let self else { return }
        lock.withLock { self.storage.append(event) }
      },
      opaqueAccountID: opaqueAccountID,
      now: { Date(timeIntervalSince1970: 3000) }
    )
  }
}

private final class CredentialLifecycleLogFixture: @unchecked Sendable {
  let directory: URL
  let url: URL
  let store: CredentialLifecycleLogStore
  private let clock: CredentialLifecycleClock

  var now: Date {
    clock.value
  }

  init(
    maximumByteCount: Int = CredentialLifecycleLogStore.defaultMaximumByteCount,
    identitySalt: Data? = Data("fixture-salt".utf8)
  ) throws {
    let clock = CredentialLifecycleClock(value: Date(timeIntervalSince1970: 2_000_000))
    self.clock = clock
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-credential-log-\(UUID().uuidString)", isDirectory: true)
    url = directory.appendingPathComponent("CredentialLifecycle.jsonl")
    store = CredentialLifecycleLogStore(
      url: url,
      maximumByteCount: maximumByteCount,
      now: { clock.value },
      identitySalt: identitySalt
    )
  }

  func advance(by interval: TimeInterval) {
    clock.value = clock.value.addingTimeInterval(interval)
  }

  func event(at timestamp: Date) -> CredentialLifecycleEvent {
    CredentialLifecycleEvent(
      timestamp: timestamp,
      provider: .claude,
      kind: .validationSucceeded,
      source: .quotariRegistry,
      accountID: "0123456789abcdef0123456789abcdef",
      interaction: .background
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class CredentialLifecycleClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Date

  init(value: Date) {
    storage = value
  }

  var value: Date {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}
