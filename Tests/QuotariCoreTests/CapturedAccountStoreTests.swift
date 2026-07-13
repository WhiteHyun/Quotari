import Foundation
@testable import QuotariCore
import Testing

/// An in-memory stand-in for the keychain so tests never touch the real one.
/// `failingServices` makes reads of matching services throw, to exercise the
/// fail-closed paths.
final class InMemoryKeychain: @unchecked Sendable {
  struct InjectedFailure: Error {}

  private let lock = NSLock()
  private var items: [String: Data] = [:]
  private var failing: Set<String> = []
  private var writeCounts: [String: Int] = [:]

  func read(_ service: String) throws -> Data? {
    try lock.withLock {
      if failing.contains(service) {
        throw InjectedFailure()
      }
      return items[service]
    }
  }

  private var failingWrites: Set<String> = []

  func write(_ data: Data, _ service: String) throws {
    try lock.withLock {
      if failingWrites.contains(service) {
        throw InjectedFailure()
      }
      items[service] = data
      writeCounts[service, default: 0] += 1
    }
  }

  func failWrites(of service: String) {
    lock.withLock { _ = failingWrites.insert(service) }
  }

  func writeCount(of service: String) -> Int {
    lock.withLock { writeCounts[service] ?? 0 }
  }

  func hasItem(_ service: String) -> Bool {
    lock.withLock { items[service] != nil }
  }

  func delete(_ service: String) {
    lock.withLock { items[service] = nil }
  }

  func failReads(of service: String) {
    lock.withLock { _ = failing.insert(service) }
  }

  func stopFailing(_ service: String) {
    lock.withLock { _ = failing.remove(service) }
  }

  var serviceCount: Int {
    lock.withLock { items.count }
  }

  var store: KeychainItemStore {
    KeychainItemStore(
      read: { try self.read($0) },
      write: { try self.write($0, $1) },
      delete: { self.delete($0) }
    )
  }
}

private func makeStore(_ keychain: InMemoryKeychain) -> CapturedAccountStore {
  CapturedAccountStore(keychain: keychain.store, service: "Test-Captured-\(UUID().uuidString)")
}

struct CapturedAccountStoreTests {
  private static func account(id: String, capturedAt: Date, token: String = "tok") -> CapturedAccount {
    CapturedAccount(
      id: id,
      provider: .codex,
      displayName: "Codex",
      detail: "Default",
      capturedAt: capturedAt,
      origin: .codexAuthFile(path: "/tmp/auth.json"),
      payload: Data(#"{"tokens":{"access_token":"\#(token)"}}"#.utf8)
    )
  }

  @Test func savesLoadsAndOrdersByCaptureTime() throws {
    let store = makeStore(InMemoryKeychain())
    try store.save(Self.account(id: "b", capturedAt: Date(timeIntervalSince1970: 200)))
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))

    #expect(store.load().map(\.id) == ["a", "b"])
  }

  @Test func savingSameIDReplacesInPlace() throws {
    let store = makeStore(InMemoryKeychain())
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100), token: "old"))
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 300), token: "new"))

    let loaded = store.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.payload == Data(#"{"tokens":{"access_token":"new"}}"#.utf8))
  }

  @Test func removeDropsOneAndClearsWhenEmpty() throws {
    let store = makeStore(InMemoryKeychain())
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    try store.save(Self.account(id: "b", capturedAt: Date(timeIntervalSince1970: 200)))

    try store.remove(id: "a")
    #expect(store.load().map(\.id) == ["b"])
    #expect(store.account(id: "a") == nil)

    try store.remove(id: "b")
    #expect(store.load().isEmpty)
  }

  @Test func emptyKeychainLoadsNothing() {
    #expect(makeStore(InMemoryKeychain()).load().isEmpty)
  }

  @Test func saveFailsClosedWhenIndexReadFailsInsteadOfErasingAccounts() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "FailTest")
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))

    // A transient read failure on the index must not let a follow-up save
    // silently rewrite the registry without the existing ids.
    keychain.failReads(of: "FailTest-Index")
    #expect(throws: (any Error).self) {
      try store.save(Self.account(id: "b", capturedAt: Date(timeIntervalSince1970: 200)))
    }

    // The original account survives once reads recover.
    keychain.stopFailing("FailTest-Index")
    #expect(store.load().map(\.id) == ["a"])
  }

  @Test func updatePayloadRewritesOnlyTheAccountItemNotTheIndex() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "UpdateTest")
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100), token: "old"))
    let indexWritesAfterSave = keychain.writeCount(of: "UpdateTest-Index")

    try store.updatePayload(id: "a") { _ in Data(#"{"tokens":{"access_token":"rotated"}}"#.utf8) }

    // A refresh writes the account item but must not write the index at all.
    #expect(keychain.writeCount(of: "UpdateTest-Index") == indexWritesAfterSave)
    #expect(store.account(id: "a")?.payload == Data(#"{"tokens":{"access_token":"rotated"}}"#.utf8))
  }

  @Test func concurrentSavesAllSurviveInTheIndex() async {
    let store = makeStore(InMemoryKeychain())
    // Without serialized index read-modify-write these would clobber each
    // other's ids; the mutation lock must let every capture survive.
    await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0 ..< 12 {
        group.addTask {
          try store.save(Self.account(id: "acct-\(i)", capturedAt: Date(timeIntervalSince1970: TimeInterval(i))))
        }
      }
    }
    #expect(store.load().count == 12)
  }

  @Test func removeRacingRefreshLeavesNoIndexedAccount() async throws {
    let store = makeStore(InMemoryKeychain())
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))

    await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try store.remove(id: "a") }
      group.addTask { try? store.updatePayload(id: "a") { _ in Data(#"{"tokens":{"access_token":"x"}}"#.utf8) } }
    }
    // Whichever ordering wins, the account must not linger in the index.
    #expect(!store.load().contains { $0.id == "a" })
  }

  @Test func removeClearsAnyPendingGrant() throws {
    let store = makeStore(InMemoryKeychain())
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    try store.savePendingGrant(Data("pending".utf8), id: "a")
    #expect(store.pendingGrantData(id: "a") == Data("pending".utf8))

    try store.remove(id: "a")

    // The pending item holds tokens; removing the account must not leave it.
    #expect(store.pendingGrantData(id: "a") == nil)
  }

  @Test func pendingGrantForARemovedAccountIsNotRecreated() throws {
    let store = makeStore(InMemoryKeychain())
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    try store.remove(id: "a")

    // An in-flight refresh finishing after removal must not leave a token
    // blob behind for an account that no longer exists.
    try store.savePendingGrant(Data("pending".utf8), id: "a")

    #expect(store.pendingGrantData(id: "a") == nil)
  }

  @Test func saveFaultAfterIndexLeavesNoOrphanedSecret() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "OrderTest")

    // Fault the account item write. Because the index is registered first, a
    // failure here leaves a harmless dangling id, never a secret item that no
    // index points at.
    keychain.failWrites(of: "OrderTest.a")
    #expect(throws: (any Error).self) {
      try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    }

    #expect(!keychain.hasItem("OrderTest.a")) // no orphaned secret
    #expect(keychain.hasItem("OrderTest-Index")) // index was written first
    #expect(store.load().isEmpty) // dangling id is skipped by load()
  }

  @Test func loadSkipsCorruptEntriesWithoutErasing() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "CorruptTest")
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    try store.save(Self.account(id: "b", capturedAt: Date(timeIntervalSince1970: 200)))

    // Corrupt one account item; load() should skip it but keep the other.
    try keychain.write(Data("not json".utf8), "CorruptTest.a")
    #expect(store.load().map(\.id) == ["b"])
    // The registry is untouched — a later valid write of "a" restores it.
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    #expect(store.load().map(\.id) == ["a", "b"])
  }
}
