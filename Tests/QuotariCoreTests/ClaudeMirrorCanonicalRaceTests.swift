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

    expectClaudeMirrorRecoveryFailure(writer, fixture.grant, replacing: "old-tok")

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

    expectClaudeMirrorRecoveryFailure(writer, fixture.grant, replacing: "old-tok")

    #expect(fixture.slot.value == unrelated)
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "new-tok")
    #expect(try fixture.pending(id: fixture.keychainPendingID) != nil)
    #expect(try fixture.pending(id: fixture.filePendingID) != nil)
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
