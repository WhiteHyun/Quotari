import Foundation
@testable import QuotariCore
import Testing

extension ClaudeMirrorRelaunchRepairTests {
  @Test func malformedMirrorKeepsRecoveryJournalsQueued() throws {
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
    let malformed = Data(#"{"claudeAiOauth":"broken"}"#.utf8)
    try malformed.write(to: fixture.fileURL)

    expectClaudeMirrorRecoveryFailure {
      try fixture.normalWriter.persist(
        fixture.grant,
        replacing: "old-tok",
        to: fixture.source
      )
    }

    #expect(fixture.keychainWrites == 1)
    #expect(try Data(contentsOf: fixture.fileURL) == malformed)
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
  }

  @Test func obsoleteCanonicalJournalWaitsForMirrorJournalCleanup() throws {
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
    fixture.failFileJournalDeletes()

    expectClaudeObsoleteCleanupFailure {
      try fixture.normalWriter.persist(
        fixture.grant,
        replacing: "old-tok",
        to: fixture.source
      )
    }

    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)

    fixture.stopFailingFileJournalDeletes()
    #expect(throws: ClaudeCredentialPersistError.self) {
      try fixture.normalWriter.persist(
        fixture.grant,
        replacing: "old-tok",
        to: fixture.source
      )
    }

    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }

  @Test func obsoleteCleanupFailureReloadsTheCanonicalGeneration() async throws {
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
    let canonical = fixture.payload(access: "other-tok", refresh: "other-ref")
    fixture.slot.value = canonical
    fixture.failFileJournalDeletes()
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: fixture.resolve,
      reloadCredentials: { _ in try fixture.resolve().credentials },
      refresher: nil,
      persister: fixture.normalWriter,
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
    #expect(resolution?.acceptedGrant == nil)
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
  }

  @Test func obsoleteCanonicalCleanupRemovesItsChainedMirrorPredecessor() throws {
    let fixture = try MirrorRepairFixture()
    defer { fixture.remove() }
    let grantB = ClaudeTokenGrant(
      accessToken: "b-token",
      refreshToken: "b-refresh",
      expiresAt: Date(timeIntervalSince1970: 50000),
      scopes: ["user:inference"]
    )
    let mirror = ClaudePendingGrant(
      grant: grantB,
      previousAccessToken: "a-token",
      consumedRefreshToken: "a-refresh"
    )
    let canonical = ClaudePendingGrant(
      grant: fixture.grant,
      previousAccessToken: "b-token",
      consumedRefreshToken: "b-refresh"
    )
    #expect(try fixture.store.saveLivePendingGrantIfAbsent(
      JSONEncoder().encode(mirror),
      id: fixture.filePendingID
    ))
    #expect(try fixture.store.saveLivePendingGrantIfAbsent(
      JSONEncoder().encode(canonical),
      id: fixture.keychainPendingID
    ))
    fixture.slot.value = fixture.payload(access: "other-tok", refresh: "other-ref")

    #expect(throws: ClaudeCredentialPersistError.self) {
      try fixture.normalWriter.persist(
        fixture.grant,
        replacing: "b-token",
        to: fixture.source
      )
    }

    #expect(try fixture.pending(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pending(id: fixture.filePendingID) == nil)
  }
}
