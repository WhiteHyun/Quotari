import Foundation
@testable import QuotariCore
import Testing

struct CredentialLifecycleDiagnosticTests {
  @Test func linksExchangeAndReadbackWithoutLoggingSecrets() async throws {
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    let registry = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: 1000)
    )
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      refresher: ClaudeTokenRefresher(transport: RefreshStubTransport(
        json: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
      )),
      capturedAccounts: registry,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      credentialLifecycleLogger: fixture.logger
    )
    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude, now: fixture.now, account: claudeRegistryAccount()
    ))
    let events = try fixture.store.events()
    let start = try #require(events.first { $0.kind == .refreshStarted }?.diagnostic)
    let endpoint = try #require(events.first { $0.kind == .tokenEndpointResponded }?.diagnostic)
    let success = try #require(events.first { $0.kind == .refreshSucceeded }?.diagnostic)
    let readback = try #require(events.last { $0.kind == .credentialObserved }?.diagnostic)
    #expect(start.operationID != nil)
    #expect([endpoint.operationID, success.operationID, readback.operationID].allSatisfy { $0 == start.operationID })
    #expect(endpoint.httpStatus == 200)
    #expect(start.generation?.refresh != success.receivedGeneration?.refresh)
    #expect(readback.storedGeneration == success.receivedGeneration)
    #expect(readback.sourceID != nil)
    let raw = try String(contentsOf: fixture.url, encoding: .utf8)
    for secret in ["old-access", "old-refresh", "new-access", "new-refresh", "claude:fp-1"] {
      #expect(!raw.contains(secret))
    }
  }

  @Test func rejectedGrantRecordsStatusCodeAndExpiredStoredGeneration() async throws {
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    let registry = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: 1000)
    )
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      refresher: ClaudeTokenRefresher(transport: RefreshStubTransport(
        json: #"{"error":"invalid_grant","error_description":"SECRET_RESPONSE"}"#, status: 400
      )),
      capturedAccounts: registry,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      credentialLifecycleLogger: fixture.logger
    )
    await #expect(throws: ClaudeTokenRefreshError.self) {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude, now: fixture.now, account: claudeRegistryAccount()
      ))
    }
    let events = try fixture.store.events()
    let endpoint = try #require(events.first { $0.kind == .tokenEndpointResponded }?.diagnostic)
    let failure = try #require(events.first { $0.kind == .refreshFailed })
    #expect(endpoint.httpStatus == 400)
    #expect(endpoint.oauthError == .invalidGrant)
    #expect(failure.failure == .reauthenticationRequired)
    #expect(failure.diagnostic?.operationID == endpoint.operationID)
    #expect(failure.diagnostic?.generation == failure.diagnostic?.storedGeneration)
    #expect(failure.diagnostic?.storageReadFailed == false)
    let incidents = try fixture.incidents()
    #expect(incidents.count == 1)
    let raw = try String(contentsOf: incidents[0], encoding: .utf8)
    #expect(!raw.contains("SECRET_RESPONSE"))
    #expect(!raw.contains("old-refresh"))
  }

  @Test func discoveryObservesMirrorsAndHiddenSavedRowsBeforeDeduplication() async throws {
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    let payload = claudePayload(accessToken: "same-access", refreshToken: "same-refresh", expiresAt: 1000)
    let registry = try makeClaudeRegistryStore(payload: payload)
    let directory = fixture.directory.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try payload.write(to: directory.appendingPathComponent(".credentials.json"))
    let discovery = ProviderAccountDiscovery(
      environment: [:], home: fixture.directory, keychainData: { payload },
      capturedAccounts: registry, credentialLifecycleLogger: fixture.logger
    )
    let accounts = await discovery.accounts(for: .claude)
    #expect(accounts.count == 1)
    let events = try fixture.store.events().filter { $0.kind == .credentialObserved }
    #expect(Set(events.compactMap(\.source)) == [.claudeKeychain, .claudeFile, .quotariRegistry])
    #expect(Set(events.compactMap { $0.diagnostic?.sourceID }).count == 3)
    #expect(Set(events.compactMap { $0.diagnostic?.generation?.refresh }).count == 1)
  }

  @Test func unchangedObservationsAreSampledButGenerationChangesAreImmediate() async throws {
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    let runtime = CredentialLifecycleLogRuntime(store: fixture.store)
    func event(_ token: String, offset: TimeInterval) -> CredentialLifecycleEvent {
      CredentialLifecycleEvent(
        timestamp: fixture.now.addingTimeInterval(offset), provider: .claude,
        kind: .credentialObserved, source: .claudeKeychain, accountID: "opaque",
        diagnostic: CredentialLifecycleDiagnostic(generation: fixture.logger
          .generation(ClaudeCredentials(accessToken: token)))
      )
    }
    runtime.record(event("first", offset: 0))
    runtime.record(event("first", offset: 1))
    runtime.record(event("second", offset: 2))
    runtime.record(event("second", offset: 901))
    runtime.record(event("second", offset: 902))
    _ = await runtime.prepareLogForAccess()
    #expect(try fixture.store.events().map(\.timestamp) == [0.0, 2.0, 902.0].map { fixture.now.addingTimeInterval($0) })
  }

  @Test func unsuccessfulStorageReadbackDoesNotMasqueradeAsInstalledGrant() async throws {
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    let registry = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: 1000)
    )
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      reloadCredentials: { _ in throw ClaudeCredentialsError.notFound },
      refresher: StubRefresher(result: .success(ClaudeTokenGrant(
        accessToken: "new-access", refreshToken: "new-refresh", expiresAt: fixture.now.addingTimeInterval(3600)
      ))),
      capturedAccounts: registry, refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      credentialLifecycleLogger: fixture.logger
    )
    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude, now: fixture.now, account: claudeRegistryAccount()
    ))
    let observed = try #require(fixture.store.events().last { $0.kind == .credentialObserved }?.diagnostic)
    #expect(observed.receivedGeneration != nil)
    #expect(observed.storedGeneration == nil)
    #expect(observed.storageReadFailed == true)
  }

  @Test func tokenDigestsAreStablePerInstallationAndLegacyEventsStillDecode() throws {
    let first = try DiagnosticFixture(salt: "first")
    let second = try DiagnosticFixture(salt: "second")
    defer { first.remove(); second.remove() }
    #expect(first.store.tokenFingerprint(for: "secret") == first.store.tokenFingerprint(for: "secret"))
    #expect(first.store.tokenFingerprint(for: "secret") != second.store.tokenFingerprint(for: "secret"))
    let legacy = Data(
      #"{"schemaVersion":1,"timestamp":"2026-10-13T00:00:00Z","provider":"claude","kind":"refreshFailed"}"#
        .utf8
    )
    let event = try #require(CredentialLifecycleLogStore.decodeLines(legacy).first)
    #expect(event.diagnostic == nil)
  }
}

struct CredentialLifecycleIncidentTests {
  @Test func firstRejectionSurvivesCompactionAndRestartWithoutBeingOverwritten() throws {
    let fixture = try DiagnosticFixture(maximumByteCount: 4000)
    defer { fixture.remove() }
    fixture.logger.record(.validationSucceeded, provider: .claude, source: .quotariRegistry(id: "saved"))
    fixture.reject(refresh: "first-refresh")
    let incident = try #require(fixture.incidents().first)
    let original = try Data(contentsOf: incident)
    #expect(CredentialLifecycleLogStore.decodeLines(original).contains { $0.kind == .validationSucceeded })
    #expect(CredentialLifecycleLogStore.decodeLines(original).last?.failure == .reauthenticationRequired)
    let restarted = CredentialLifecycleLogStore(url: fixture.url, maximumByteCount: 4000, now: { fixture.now })
    for offset in 0 ..< 100 {
      try restarted.record(CredentialLifecycleEvent(
        timestamp: fixture.now.addingTimeInterval(Double(offset)), provider: .claude, kind: .monitoringPass
      ))
    }
    let firstFailure = try #require(CredentialLifecycleLogStore.decodeLines(original).last)
    try restarted.record(firstFailure)
    #expect(try Data(contentsOf: incident) == original)
    #expect(try Data(contentsOf: fixture.url).count <= 4000)
    fixture.reject(refresh: "new-refresh")
    #expect(try fixture.incidents().count == 2)
    let attributes = try FileManager.default.attributesOfItem(atPath: incident.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func unavailableIncidentDirectoryDoesNotDisableMainLogCompaction() throws {
    let fixture = try DiagnosticFixture(maximumByteCount: 4000)
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try Data("blocked".utf8).write(to: fixture.store.incidentsDirectory)
    for index in 0 ..< 30 {
      fixture.reject(refresh: "refresh-\(index)")
    }
    #expect(try Data(contentsOf: fixture.url).count <= 4000)
    #expect(try fixture.store.events().last?.failure == .reauthenticationRequired)
  }

  @Test func incidentCountAndAgeAreBounded() throws {
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    for index in 0 ..< 12 {
      fixture.reject(refresh: "refresh-\(index)")
    }
    #expect(try fixture.incidents().count == 8)
    let old = fixture.now.addingTimeInterval(-22 * 24 * 60 * 60)
    for file in try fixture.incidents() {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
    }
    try fixture.store.performMaintenance()
    #expect(try fixture.incidents().isEmpty)
  }
}

private struct DiagnosticFixture: Sendable {
  let directory: URL
  let url: URL
  let store: CredentialLifecycleLogStore
  let now = Date(timeIntervalSince1970: 2_000_000)

  init(maximumByteCount: Int = 5 * 1024 * 1024, salt: String = "fixture") throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    url = directory.appendingPathComponent("CredentialLifecycle.jsonl")
    store = CredentialLifecycleLogStore(
      url: url, maximumByteCount: maximumByteCount,
      now: { Date(timeIntervalSince1970: 2_000_000) }, identitySalt: Data(salt.utf8)
    )
  }

  var logger: CredentialLifecycleLogger {
    CredentialLifecycleLogger(
      record: { try? store.record($0) },
      opaqueAccountID: { store.opaqueIdentifier(for: $0) },
      now: { now }, tokenFingerprint: { store.tokenFingerprint(for: $0) }
    )
  }

  func reject(refresh: String) {
    logger.record(
      .refreshFailed, provider: .claude, source: .quotariRegistry(id: "saved"),
      failure: .reauthenticationRequired,
      diagnostic: CredentialLifecycleDiagnostic(generation: logger.generation(ClaudeCredentials(
        accessToken: "access", refreshToken: refresh
      )))
    )
  }

  func incidents() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: store.incidentsDirectory, includingPropertiesForKeys: nil)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
