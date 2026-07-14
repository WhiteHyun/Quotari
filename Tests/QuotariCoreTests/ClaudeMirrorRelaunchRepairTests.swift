import Foundation
@testable import QuotariCore
import Testing

enum MirrorFailureStage: CaseIterable, Sendable {
  case read
  case permission
  case rename
}

struct ClaudeMirrorRelaunchRepairTests {
  @Test(arguments: MirrorFailureStage.allCases)
  func failedMirrorIORepairsWithoutRewritingTheInstalledKeychain(
    stage: MirrorFailureStage
  ) throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let original = fixture.payload(access: "old-tok", refresh: "old-ref")
    try original.write(to: fixture.fileURL)
    fixture.slot.value = original
    let grant = fixture.grant

    expectClaudeMirrorRecoveryFailure {
      try fixture.failingWriter(stage: stage).persist(
        grant,
        replacing: "old-tok",
        to: fixture.source
      )
    }

    #expect(fixture.reachedFailureStage(stage))
    #expect(fixture.keychainWrites == 1)
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
    #expect(try Data(contentsOf: fixture.fileURL) == original)

    try fixture.normalWriter.persist(
      grant,
      replacing: "old-tok",
      to: fixture.source
    )

    #expect(fixture.keychainWrites == 1)
    let repaired = try JSONSerialization.jsonObject(
      with: Data(contentsOf: fixture.fileURL)
    ) as? [String: Any]
    let oauth = repaired?["claudeAiOauth"] as? [String: Any]
    #expect(oauth?["accessToken"] as? String == "new-tok")
    #expect(oauth?["refreshToken"] as? String == "new-ref")
    #expect(repaired?["mcpOAuth"] != nil)
    #expect(repaired?["unknown"] as? String == "kept")
    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }

  @Test func nextFetchRepairsTheMirrorWithoutAnotherTokenExchange() async throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let original = fixture.payload(access: "old-tok", refresh: "old-ref", expiresAt: 1000)
    try original.write(to: fixture.fileURL)
    fixture.slot.value = original
    let firstLaunch = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: fixture.resolve,
      refresher: StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse)),
      persister: fixture.failingWriter(stage: .rename),
      capturedAccounts: fixture.store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )
    let pending = ClaudePendingGrant(
      grant: fixture.grant,
      previousAccessToken: "old-tok",
      consumedRefreshToken: "old-ref"
    )
    let firstResolution = try await firstLaunch.persisted(
      pending,
      resolved: ResolvedClaudeCredentials(
        credentials: ClaudeCredentialsStore.parse(original),
        source: fixture.source
      )
    )
    #expect(firstResolution?.resolved.credentials.accessToken == "new-tok")
    #expect(fixture.keychainWrites == 1)
    #expect(try Data(contentsOf: fixture.fileURL) == original)
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)

    let secondRefresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse))
    let secondLaunch = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: fixture.resolve,
      refresher: secondRefresher,
      persister: fixture.normalWriter,
      capturedAccounts: fixture.store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )

    _ = try await secondLaunch.fetch(
      ProviderFetchContext(
        provider: .claude,
        now: Date(timeIntervalSince1970: 2000)
      )
    )

    #expect(secondRefresher.calls.isEmpty)
    #expect(fixture.keychainWrites == 1)
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "new-tok")
    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }

  @Test func unrelatedFileGenerationIsNeverOverwrittenByRelaunchRepair() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let original = fixture.payload(access: "old-tok", refresh: "old-ref")
    try original.write(to: fixture.fileURL)
    fixture.slot.value = original
    expectClaudeMirrorRecoveryFailure {
      try fixture.failingWriter(stage: .rename).persist(
        fixture.grant,
        replacing: "old-tok",
        to: fixture.source
      )
    }
    let unrelated = fixture.payload(access: "other-tok", refresh: "other-ref")
    try unrelated.write(to: fixture.fileURL)

    try fixture.normalWriter.persist(
      fixture.grant,
      replacing: "old-tok",
      to: fixture.source
    )

    #expect(fixture.keychainWrites == 1)
    #expect(try Data(contentsOf: fixture.fileURL) == unrelated)
    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }

  @Test func unrelatedKeychainGenerationMakesTheQueuedMirrorObsolete() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let original = fixture.payload(access: "old-tok", refresh: "old-ref")
    try original.write(to: fixture.fileURL)
    fixture.slot.value = original
    expectClaudeMirrorRecoveryFailure {
      try fixture.failingWriter(stage: .rename).persist(
        fixture.grant,
        replacing: "old-tok",
        to: fixture.source
      )
    }
    fixture.slot.value = fixture.payload(access: "other-tok", refresh: "other-ref")

    do {
      try fixture.normalWriter.persist(
        fixture.grant,
        replacing: "old-tok",
        to: fixture.source
      )
      Issue.record("expected staleSource")
    } catch let error as ClaudeCredentialPersistError {
      guard case .staleSource = error else {
        Issue.record("expected staleSource, got \(error)")
        return
      }
    }

    #expect(fixture.keychainWrites == 1)
    #expect(try Data(contentsOf: fixture.fileURL) == original)
    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }

  @Test func journalStorageFailureIsTypedAndKeepsTheGrantInMemory() async throws {
    let fixture = try MirrorRepairFixture(
      keychainService: "Test-Claude-Code-\(UUID().uuidString)"
    )
    defer { fixture.remove() }
    let original = fixture.payload(access: "old-tok", refresh: "old-ref", expiresAt: 1000)
    try original.write(to: fixture.fileURL)
    fixture.slot.value = original
    fixture.failCanonicalJournalWrites()

    do {
      try fixture.normalWriter.persist(
        fixture.grant,
        replacing: "old-tok",
        to: fixture.source
      )
      Issue.record("expected recoveryJournalFailed")
    } catch let error as ClaudeCredentialPersistError {
      guard case .recoveryJournalFailed = error else {
        Issue.record("expected recoveryJournalFailed, got \(error)")
        return
      }
    }
    #expect(fixture.keychainWrites == 0)

    let coordinator = ClaudeTokenRefreshCoordinator()
    let recorder = RefreshStubTransport.Recorder()
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON, recorder: recorder),
      resolveCredentials: fixture.resolve,
      refresher: StubRefresher(result: .success(fixture.grant)),
      persister: fixture.normalWriter,
      capturedAccounts: fixture.store,
      refreshCoordinator: coordinator
    )

    _ = try await strategy.fetch(
      ProviderFetchContext(
        provider: .claude,
        now: Date(timeIntervalSince1970: 2000)
      )
    )

    let expected = ClaudePendingGrant(
      grant: fixture.grant,
      previousAccessToken: "old-tok",
      consumedRefreshToken: "old-ref"
    )
    #expect(fixture.keychainWrites == 0)
    #expect(recorder.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer new-tok")
    #expect(await coordinator.takeUnpersisted(sourceID: fixture.source.stableID) == expected)
  }
}

final class MirrorRepairFixture: @unchecked Sendable {
  struct InjectedFailure: Error {}

  let directory: URL
  let fileURL: URL
  let source: ProviderCredentialSource
  let keychainPendingID: String
  let filePendingID: String
  let store: CapturedAccountStore
  let slot = KeychainSlot()
  let grant = ClaudeTokenGrant(
    accessToken: "new-tok",
    refreshToken: "new-ref",
    expiresAt: Date(timeIntervalSince1970: 100_000),
    scopes: ["user:inference"]
  )

  private let lock = NSLock()
  private var writeCount = 0
  private var reachedFailureStages: Set<MirrorFailureStage> = []
  private let registryKeychain: InMemoryKeychain
  private let registryService: String

  var keychainWrites: Int {
    lock.withLock { writeCount }
  }

  var resolve: @Sendable () throws -> ResolvedClaudeCredentials {
    {
      guard let payload = self.slot.value else {
        throw ClaudeCredentialPersistError.sourceUnavailable
      }
      return try ResolvedClaudeCredentials(
        credentials: ClaudeCredentialsStore.parse(payload),
        source: self.source
      )
    }
  }

  var normalWriter: ClaudeCredentialsWriter {
    writer()
  }

  init(keychainService: String = ClaudeCredentialsStore.keychainService) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-mirror-relaunch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent(".credentials.json")
    source = .claudeKeychain(service: keychainService)
    keychainPendingID = try #require(source.claudeLivePendingGrantID)
    filePendingID = try #require(
      ProviderCredentialSource
        .claudeCredentialsFile(path: fileURL.standardizedFileURL.path)
        .claudeLivePendingGrantID
    )
    registryKeychain = InMemoryKeychain()
    registryService = "Test-ClaudeMirrorRelaunch-\(UUID().uuidString)"
    store = CapturedAccountStore(keychain: registryKeychain.store, service: registryService)
  }

  func payload(
    access: String,
    refresh: String,
    expiresAt: TimeInterval = 100_000
  ) -> Data {
    let milliseconds = Int(expiresAt * 1000)
    return Data(
      """
      {
        "claudeAiOauth": {
          "accessToken": "\(access)",
          "refreshToken": "\(refresh)",
          "expiresAt": \(milliseconds),
          "scopes": ["user:inference"]
        },
        "mcpOAuth": {"linear": {"accessToken": "mcp"}},
        "unknown": "kept"
      }
      """.utf8
    )
  }

  func failingWriter(stage: MirrorFailureStage) -> ClaudeCredentialsWriter {
    let secureWriter = SecureCredentialFileWriter(setOwnerOnlyPermissions: { _ in })
    return writer(
      fileRead: { url in
        if stage == .read {
          self.markFailureStage(stage)
          throw InjectedFailure()
        }
        return try Data(contentsOf: url)
      },
      setOwnerOnlyPermissions: { url in
        if stage == .permission {
          self.markFailureStage(stage)
          throw InjectedFailure()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      },
      commitMirroredFile: { temporary, destination in
        if stage == .rename {
          self.markFailureStage(stage)
          throw InjectedFailure()
        }
        try secureWriter.commit(temporary, replacing: destination)
      }
    )
  }

  func reachedFailureStage(_ stage: MirrorFailureStage) -> Bool {
    lock.withLock { reachedFailureStages.contains(stage) }
  }

  func pending(id: String) throws -> ClaudePendingGrant? {
    guard let data = try store.loadPendingGrantData(id: id) else { return nil }
    return try JSONDecoder().decode(ClaudePendingGrant.self, from: data)
  }

  func failCanonicalJournalWrites() {
    registryKeychain.failWrites(of: "\(registryService).pending.\(keychainPendingID)")
  }

  func failFileJournalDeletes() {
    registryKeychain.failDeletes(of: "\(registryService).pending.\(filePendingID)")
  }

  func stopFailingFileJournalDeletes() {
    registryKeychain.stopFailingDeletes(of: "\(registryService).pending.\(filePendingID)")
  }

  private func markFailureStage(_ stage: MirrorFailureStage) {
    lock.withLock { _ = reachedFailureStages.insert(stage) }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func writer(
    keychainRead: (@Sendable (String) -> Data?)? = nil,
    fileRead: (@Sendable (URL) throws -> Data)? = nil,
    setOwnerOnlyPermissions: (@Sendable (URL) throws -> Void)? = nil,
    commitMirroredFile: (@Sendable (URL, URL) throws -> Void)? = nil
  ) -> ClaudeCredentialsWriter {
    ClaudeCredentialsWriter(
      keychainRead: keychainRead ?? { _ in self.slot.value },
      keychainWrite: { data, _ in
        self.lock.withLock { self.writeCount += 1 }
        self.slot.value = data
      },
      capturedAccounts: store,
      mirroredCredentialsFileURL: fileURL,
      fileRead: fileRead,
      setOwnerOnlyPermissions: setOwnerOnlyPermissions,
      commitMirroredFile: commitMirroredFile
    )
  }
}
