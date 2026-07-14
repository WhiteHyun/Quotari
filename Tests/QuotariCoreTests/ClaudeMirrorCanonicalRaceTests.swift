import Foundation
@testable import QuotariCore
import Testing

extension ClaudeMirrorRelaunchRepairTests {
  @Test func canonicalChangeBeforeMirrorCommitLeavesTheFileAndJournalsUntouched() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let original = try queueMirrorRepair(in: fixture)
    let unrelated = fixture.payload(access: "other-tok", refresh: "other-ref")
    let reads = RaceReadCounter()
    let writer = fixture.writer(keychainRead: { _ in
      if reads.next() == 2 {
        fixture.slot.value = unrelated
      }
      return fixture.slot.value
    })

    expectClaudeMirrorOwnerChange(writer, fixture.grant, replacing: "old-tok")

    #expect(fixture.slot.value == unrelated)
    #expect(try Data(contentsOf: fixture.fileURL) == original)
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
  }

  @Test func canonicalChangeDuringMirrorCommitRetainsRecoveryOwnership() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    _ = try queueMirrorRepair(in: fixture)
    let unrelated = fixture.payload(access: "other-tok", refresh: "other-ref")
    let secureWriter = SecureCredentialFileWriter(setOwnerOnlyPermissions: { _ in })
    let writer = fixture.writer(commitMirroredFile: { temporary, destination in
      fixture.slot.value = unrelated
      try secureWriter.commit(temporary, replacing: destination)
    })

    expectClaudeMirrorOwnerChange(writer, fixture.grant, replacing: "old-tok")

    #expect(fixture.slot.value == unrelated)
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "new-tok")
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
  }

  @Test func canonicalMetadataChangeWithSameGrantCompletesMirrorRepair() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    _ = try queueMirrorRepair(in: fixture)
    let canonicalPayload = try #require(fixture.slot.value)
    var metadataRewrite = try #require(
      JSONSerialization.jsonObject(with: canonicalPayload) as? [String: Any]
    )
    metadataRewrite["unknown"] = "changed"
    let rewrittenPayload = try JSONSerialization.data(withJSONObject: metadataRewrite)
    let reads = RaceReadCounter()
    let writer = fixture.writer(keychainRead: { _ in
      if reads.next() == 2 {
        fixture.slot.value = rewrittenPayload
      }
      return fixture.slot.value
    })

    try writer.persist(fixture.grant, replacing: "old-tok", to: fixture.source)

    #expect(fixture.slot.value == rewrittenPayload)
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "new-tok")
    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }

  @Test func canonicalChangeDuringRepairKeepsBothJournalsForObsoleteCleanup() async throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let original = try queueMirrorRepair(in: fixture)
    let unrelated = fixture.payload(access: "other-tok", refresh: "other-ref")
    let secureWriter = SecureCredentialFileWriter(setOwnerOnlyPermissions: { _ in })
    let writer = fixture.writer(commitMirroredFile: { temporary, destination in
      fixture.slot.value = unrelated
      try secureWriter.commit(temporary, replacing: destination)
    })
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: fixture.resolve,
      reloadCredentials: { _ in try fixture.resolve().credentials },
      refresher: nil,
      persister: writer,
      capturedAccounts: fixture.store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )
    let pending = ClaudePendingGrant(
      grant: fixture.grant,
      previousAccessToken: "old-tok",
      consumedRefreshToken: "old-ref"
    )

    let resolution = try await strategy.persisted(
      pending,
      resolved: ResolvedClaudeCredentials(
        credentials: ClaudeCredentialsStore.parse(original),
        source: fixture.source
      )
    )

    #expect(resolution?.resolved.credentials.accessToken == "other-tok")
    #expect(resolution?.resolved.credentials.refreshToken == "other-ref")
    #expect(resolution?.acceptedGrant == nil)
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)

    #expect(throws: ClaudeCredentialPersistError.self) {
      try fixture.normalWriter.persist(fixture.grant, replacing: "old-tok", to: fixture.source)
    }
    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }

  @Test func changedMirrorUsesReconciledRecoveryLineage() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let fileA = fixture.payload(access: "a-token", refresh: "a-refresh")
    let fileB = fixture.payload(access: "b-token", refresh: "b-refresh")
    let keychainC = fixture.payload(access: "new-tok", refresh: "new-ref")
    try fileB.write(to: fixture.fileURL)
    fixture.slot.value = keychainC
    let canonical = ClaudePendingGrant(
      grant: fixture.grant,
      previousAccessToken: "b-token",
      consumedRefreshToken: "b-refresh"
    )
    let mirrored = ClaudePendingGrant(
      grant: fixture.grant,
      previousAccessToken: "b-token",
      consumedRefreshToken: "b-refresh",
      priorAccessTokens: ["a-token"],
      priorConsumedRefreshTokens: ["a-refresh"]
    )
    #expect(try fixture.store.saveLivePendingGrantIfAbsent(
      JSONEncoder().encode(canonical),
      id: fixture.keychainPendingID
    ))
    #expect(try fixture.store.saveLivePendingGrantIfAbsent(
      JSONEncoder().encode(mirrored),
      id: fixture.filePendingID
    ))
    let reads = RaceReadCounter()
    let writer = fixture.writer(fileRead: { destination in
      if reads.next() == 3 {
        try fileA.write(to: destination)
      }
      return try Data(contentsOf: destination)
    })

    expectClaudeMirrorRecoveryFailure(writer, fixture.grant, replacing: "b-token")

    #expect(try Data(contentsOf: fixture.fileURL) == fileA)
    #expect(try fixture.pending(id: fixture.keychainPendingID) == canonical)
    #expect(try fixture.pending(id: fixture.filePendingID) == mirrored)
  }

  @Test func indeterminateMirrorAbsenceRetainsRecoveryOwnership() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    _ = try queueMirrorRepair(in: fixture)
    try FileManager.default.removeItem(at: fixture.fileURL)
    let writer = fixture.writer(fileRead: { _ in
      throw CocoaError(.fileReadNoPermission)
    })

    expectClaudeMirrorRecoveryFailure(writer, fixture.grant, replacing: "old-tok")

    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
  }

  @Test func unavailableCanonicalStateRetainsRecoveryOwnership() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let original = try queueMirrorRepair(in: fixture)
    let reads = RaceReadCounter()
    let writer = fixture.writer(keychainRead: { _ in
      reads.next() == 2 ? nil : fixture.slot.value
    })

    expectClaudeMirrorRecoveryFailure(writer, fixture.grant, replacing: "old-tok")

    #expect(try Data(contentsOf: fixture.fileURL) == original)
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
  }

  private func queueMirrorRepair(in fixture: MirrorRepairFixture) throws -> Data {
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
    return original
  }

  private func expectClaudeMirrorOwnerChange(
    _ writer: ClaudeCredentialsWriter,
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String
  ) {
    do {
      try writer.persist(grant, replacing: previousAccessToken, to: .claudeKeychain(
        service: ClaudeCredentialsStore.keychainService
      ))
      Issue.record("expected mirrorRecoveryOwnerChanged")
    } catch let error as ClaudeCredentialPersistError {
      guard case .mirrorRecoveryOwnerChanged = error else {
        Issue.record("expected mirrorRecoveryOwnerChanged, got \(error)")
        return
      }
    } catch {
      Issue.record("expected mirrorRecoveryOwnerChanged, got \(error)")
    }
  }
}

private final class RaceReadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}
