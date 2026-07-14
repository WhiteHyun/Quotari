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

    #expect(throws: ClaudeCredentialPersistError.self) {
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
}
