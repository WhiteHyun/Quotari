import Foundation
@testable import QuotariCore
import Testing

struct ClaudeMirrorRecoveryJournalTests {
  @Test func mirrorRecoveryIsJournaledBeforeTheCanonicalKeychainWrite() throws {
    final class Box: @unchecked Sendable {
      var fileJournalAtWrite: ClaudePendingGrant?
      var keychainJournalAtWrite: ClaudePendingGrant?
      var keychainJournalAtFirstMirrorRead: ClaudePendingGrant?
      var observedMirrorRead = false
    }
    let box = Box()
    let fixture = try MirrorJournalFixture()
    defer { fixture.remove() }
    let original = fixture.payload(access: "a-token", refresh: "a-refresh")
    try original.write(to: fixture.fileURL)
    let grant = ClaudeTokenGrant(accessToken: "b-token", refreshToken: "b-refresh")
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in original },
      keychainWrite: { _, _ in
        box.fileJournalAtWrite = try fixture.pendingGrant(id: fixture.pendingID)
        box.keychainJournalAtWrite = try fixture.pendingGrant(id: fixture.keychainPendingID)
        throw MirrorJournalFixture.InjectedFailure()
      },
      capturedAccounts: fixture.store,
      mirroredCredentialsFileURL: fixture.fileURL,
      fileRead: { url in
        if !box.observedMirrorRead {
          box.observedMirrorRead = true
          box.keychainJournalAtFirstMirrorRead = try fixture.pendingGrant(
            id: fixture.keychainPendingID
          )
        }
        return try Data(contentsOf: url)
      }
    )

    #expect(throws: MirrorJournalFixture.InjectedFailure.self) {
      try writer.persist(
        grant,
        replacing: "a-token",
        to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
      )
    }

    for journal in [box.fileJournalAtWrite, box.keychainJournalAtWrite] {
      let journal = try #require(journal)
      #expect(journal.grant == grant)
      #expect(journal.previousAccessToken == "a-token")
      #expect(journal.consumedRefreshToken == "a-refresh")
      #expect(journal.liveSourceBackupRecorded == nil)
    }
    #expect(box.keychainJournalAtFirstMirrorRead == box.keychainJournalAtWrite)
  }

  @Test func canonicalRecoveryDoesNotDependOnAMirrorFile() throws {
    final class Box: @unchecked Sendable { var journalAtWrite: ClaudePendingGrant? }
    let box = Box()
    let fixture = try MirrorJournalFixture()
    defer { fixture.remove() }
    let original = fixture.payload(access: "a-token", refresh: "a-refresh")
    let grant = ClaudeTokenGrant(accessToken: "b-token", refreshToken: "b-refresh")
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in original },
      keychainWrite: { _, _ in
        box.journalAtWrite = try fixture.pendingGrant(id: fixture.keychainPendingID)
        throw MirrorJournalFixture.InjectedFailure()
      },
      capturedAccounts: fixture.store
    )

    #expect(throws: MirrorJournalFixture.InjectedFailure.self) {
      try writer.persist(
        grant,
        replacing: "a-token",
        to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
      )
    }

    let journal = try #require(box.journalAtWrite)
    #expect(journal.grant == grant)
    #expect(journal.previousAccessToken == "a-token")
    #expect(journal.consumedRefreshToken == "a-refresh")
  }

  @Test func aSecondRotationComposesTheExistingMirrorRecovery() throws {
    final class Box: @unchecked Sendable { var keychain: Data? }
    let box = Box()
    let fixture = try MirrorJournalFixture()
    defer { fixture.remove() }
    let fileA = fixture.payload(access: "a-token", refresh: "a-refresh")
    let keychainB = fixture.payload(access: "b-token", refresh: "b-refresh")
    try fileA.write(to: fixture.fileURL)
    try fixture.savePending(ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "b-token", refreshToken: "b-refresh"),
      previousAccessToken: "a-token",
      consumedRefreshToken: "a-refresh"
    ))
    let grantC = ClaudeTokenGrant(accessToken: "c-token", refreshToken: "c-refresh")
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in keychainB },
      keychainWrite: { data, _ in box.keychain = data },
      capturedAccounts: fixture.store,
      mirroredCredentialsFileURL: fixture.fileURL,
      commitMirroredFile: { _, _ in throw MirrorJournalFixture.InjectedFailure() }
    )

    try writer.persist(
      grantC,
      replacing: "b-token",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    let keychainC = try #require(box.keychain)
    #expect(try ClaudeCredentialsStore.parse(keychainC).accessToken == "c-token")
    #expect(try Data(contentsOf: fixture.fileURL) == fileA)
    let storedJournal = try fixture.pendingGrant(id: fixture.pendingID)
    let journal = try #require(storedJournal)
    #expect(journal.grant == grantC)
    #expect(journal.previousAccessToken == "b-token")
    #expect(journal.consumedRefreshToken == "b-refresh")
    #expect(journal.supersedes(accessToken: "a-token", refreshToken: "a-refresh"))
    #expect(journal.supersedes(accessToken: "b-token", refreshToken: "b-refresh"))
    #expect(journal.liveSourceBackupRecorded == nil)
    #expect(try fixture.pendingGrant(id: fixture.keychainPendingID) == nil)

    let service = AccountSwitchService(capturedAccounts: fixture.store)
    let resolved = try service.resolveClaudeLivePendingGrants(
      [.init(id: fixture.pendingID, pending: journal)],
      keychain: keychainC,
      file: fileA
    )
    #expect(try ClaudeCredentialsStore.parse(#require(resolved.keychain)).accessToken == "c-token")
    #expect(try ClaudeCredentialsStore.parse(#require(resolved.file)).accessToken == "c-token")
  }

  @Test func canonicalJournalRecoversACrashBeforeTheKeychainWrite() throws {
    final class Box: @unchecked Sendable {
      var keychain: Data?
      var failWrite = true
    }
    let box = Box()
    let fixture = try MirrorJournalFixture()
    defer { fixture.remove() }
    let fileA = fixture.payload(access: "a-token", refresh: "a-refresh")
    let keychainB = fixture.payload(access: "b-token", refresh: "b-refresh")
    try fileA.write(to: fixture.fileURL)
    try fixture.savePending(ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "b-token", refreshToken: "b-refresh"),
      previousAccessToken: "a-token",
      consumedRefreshToken: "a-refresh"
    ))
    let grantC = ClaudeTokenGrant(accessToken: "c-token", refreshToken: "c-refresh")
    let crashingWriter = ClaudeCredentialsWriter(
      keychainRead: { _ in keychainB },
      keychainWrite: { data, _ in
        if box.failWrite { throw MirrorJournalFixture.InjectedFailure() }
        box.keychain = data
      },
      capturedAccounts: fixture.store,
      mirroredCredentialsFileURL: fixture.fileURL
    )

    #expect(throws: MirrorJournalFixture.InjectedFailure.self) {
      try crashingWriter.persist(
        grantC,
        replacing: "b-token",
        to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
      )
    }

    let storedCanonical = try fixture.pendingGrant(id: fixture.keychainPendingID)
    let canonical = try #require(storedCanonical)
    #expect(canonical.grant == grantC)
    #expect(canonical.supersedes(accessToken: "b-token", refreshToken: "b-refresh"))
    let storedMirror = try fixture.pendingGrant(id: fixture.pendingID)
    let mirrored = try #require(storedMirror)
    #expect(mirrored.grant == grantC)
    #expect(mirrored.supersedes(accessToken: "a-token", refreshToken: "a-refresh"))

    box.failWrite = false
    try crashingWriter.persist(
      canonical.grant,
      replacing: canonical.previousAccessToken,
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    #expect(try ClaudeCredentialsStore.parse(#require(box.keychain)).accessToken == "c-token")
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "c-token")
    #expect(try fixture.pendingGrant(id: fixture.keychainPendingID) == nil)
    #expect(try fixture.pendingGrant(id: fixture.pendingID) == nil)
  }

  @Test func recomposingAPreparedMirrorDoesNotLeakItsFirstTemporaryFile() throws {
    final class Box: @unchecked Sendable { var keychain: Data? }
    let box = Box()
    let fixture = try MirrorJournalFixture()
    defer { fixture.remove() }
    let keychainB = fixture.payload(access: "b-token", refresh: "b-refresh")
    try keychainB.write(to: fixture.fileURL)
    try fixture.savePending(ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "b-token", refreshToken: "b-refresh"),
      previousAccessToken: "a-token",
      consumedRefreshToken: "a-refresh"
    ))
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in keychainB },
      keychainWrite: { data, _ in box.keychain = data },
      capturedAccounts: fixture.store,
      mirroredCredentialsFileURL: fixture.fileURL,
      commitMirroredFile: { _, _ in throw MirrorJournalFixture.InjectedFailure() }
    )

    try writer.persist(
      ClaudeTokenGrant(accessToken: "c-token", refreshToken: "c-refresh"),
      replacing: "b-token",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    let files = try FileManager.default.contentsOfDirectory(
      at: fixture.directory,
      includingPropertiesForKeys: nil
    )
    #expect(files.filter { $0.lastPathComponent.contains(".quotari.") }.isEmpty)
  }

  @Test func markedCleanupDebtIsReplacedByTheNextMirrorGrant() throws {
    final class Box: @unchecked Sendable { var keychain: Data? }
    let box = Box()
    let fixture = try MirrorJournalFixture()
    defer { fixture.remove() }
    let original = fixture.payload(access: "a-token", refresh: "a-refresh")
    try original.write(to: fixture.fileURL)
    try fixture.savePending(ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "old-result", refreshToken: "old-result-refresh"),
      previousAccessToken: "old-source",
      consumedRefreshToken: "old-source-refresh",
      liveSourceBackupRecorded: true
    ))
    let grant = ClaudeTokenGrant(accessToken: "b-token", refreshToken: "b-refresh")
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in original },
      keychainWrite: { data, _ in box.keychain = data },
      capturedAccounts: fixture.store,
      mirroredCredentialsFileURL: fixture.fileURL,
      commitMirroredFile: { _, _ in throw MirrorJournalFixture.InjectedFailure() }
    )

    try writer.persist(
      grant,
      replacing: "a-token",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    #expect(try ClaudeCredentialsStore.parse(#require(box.keychain)).accessToken == "b-token")
    let storedJournal = try fixture.pendingGrant(id: fixture.pendingID)
    let journal = try #require(storedJournal)
    #expect(journal.grant == grant)
    #expect(journal.previousAccessToken == "a-token")
    #expect(journal.consumedRefreshToken == "a-refresh")
    #expect(journal.liveSourceBackupRecorded == nil)
  }

  @Test func markedPredecessorStillBridgesAStaleMirror() throws {
    final class Box: @unchecked Sendable { var keychain: Data? }
    let box = Box()
    let fixture = try MirrorJournalFixture()
    defer { fixture.remove() }
    let fileA = fixture.payload(access: "a-token", refresh: "a-refresh")
    let keychainB = fixture.payload(access: "b-token", refresh: "b-refresh")
    try fileA.write(to: fixture.fileURL)
    try fixture.savePending(ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "b-token", refreshToken: "b-refresh"),
      previousAccessToken: "a-token",
      consumedRefreshToken: "a-refresh",
      liveSourceBackupRecorded: true
    ))
    let grantC = ClaudeTokenGrant(accessToken: "c-token", refreshToken: "c-refresh")
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in keychainB },
      keychainWrite: { data, _ in box.keychain = data },
      capturedAccounts: fixture.store,
      mirroredCredentialsFileURL: fixture.fileURL,
      commitMirroredFile: { _, _ in throw MirrorJournalFixture.InjectedFailure() }
    )

    try writer.persist(
      grantC,
      replacing: "b-token",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    #expect(try ClaudeCredentialsStore.parse(#require(box.keychain)).accessToken == "c-token")
    let storedJournal = try fixture.pendingGrant(id: fixture.pendingID)
    let journal = try #require(storedJournal)
    #expect(journal.grant == grantC)
    #expect(journal.supersedes(accessToken: "a-token", refreshToken: "a-refresh"))
    #expect(journal.supersedes(accessToken: "b-token", refreshToken: "b-refresh"))
    #expect(journal.liveSourceBackupRecorded == nil)
  }
}

private struct MirrorJournalFixture {
  struct InjectedFailure: Error {}

  let directory: URL
  let fileURL: URL
  let store: CapturedAccountStore
  let pendingID: String
  let keychainPendingID: String

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-mirror-journal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent(".credentials.json")
    store = CapturedAccountStore(
      keychain: InMemoryKeychain().store,
      service: "Test-ClaudeMirrorJournal-\(UUID().uuidString)"
    )
    pendingID = try #require(
      ProviderCredentialSource
        .claudeCredentialsFile(path: fileURL.standardizedFileURL.path)
        .claudeLivePendingGrantID
    )
    keychainPendingID = try #require(
      ProviderCredentialSource
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
        .claudeLivePendingGrantID
    )
  }

  func payload(access: String, refresh: String) -> Data {
    Data(
      #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"},"kept":"value"}"#.utf8
    )
  }

  func savePending(_ pending: ClaudePendingGrant) throws {
    #expect(try store.saveLivePendingGrantIfAbsent(JSONEncoder().encode(pending), id: pendingID))
  }

  func pendingGrant(id: String) throws -> ClaudePendingGrant? {
    guard let data = try store.loadPendingGrantData(id: id) else { return nil }
    return try JSONDecoder().decode(ClaudePendingGrant.self, from: data)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
