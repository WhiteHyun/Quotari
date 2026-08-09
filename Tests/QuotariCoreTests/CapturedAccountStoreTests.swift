import Foundation
@testable import QuotariCore
import Testing
// swiftlint:disable file_length

extension CapturedAccountStore {
  func pendingGrantData(id: String) -> Data? {
    try? loadPendingGrantData(id: id)
  }
}

/// An in-memory stand-in for the keychain so tests never touch the real one.
/// `failingServices` makes reads of matching services throw, to exercise the
/// fail-closed paths.
final class InMemoryKeychain: @unchecked Sendable {
  struct InjectedFailure: Error {}

  private let lock = NSLock()
  private var items: [String: Data] = [:]
  private var failing: Set<String> = []
  private var writeCounts: [String: Int] = [:]
  private var failingDeletes: Set<String> = []

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

  func stopFailingWrites(of service: String) {
    lock.withLock { _ = failingWrites.remove(service) }
  }

  func writeCount(of service: String) -> Int {
    lock.withLock { writeCounts[service] ?? 0 }
  }

  func hasItem(_ service: String) -> Bool {
    lock.withLock { items[service] != nil }
  }

  func delete(_ service: String) throws {
    try lock.withLock {
      if failingDeletes.contains(service) {
        throw InjectedFailure()
      }
      items[service] = nil
    }
  }

  func failDeletes(of service: String) {
    lock.withLock { _ = failingDeletes.insert(service) }
  }

  func stopFailingDeletes(of service: String) {
    lock.withLock { _ = failingDeletes.remove(service) }
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
      delete: { try self.delete($0) }
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

  @Test func authoritativeRegistrySnapshotFailsWhenTheIndexCannotBeRead() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "SnapshotTest")
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    keychain.failReads(of: "SnapshotTest-Index")

    #expect(throws: (any Error).self) {
      try store.registeredAccounts(for: .claude)
    }
  }

  @Test func strictRegistrySnapshotFailsWhenAnyIndexedAccountCannotBeRead() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "StrictSnapshotTest")
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))
    keychain.failReads(of: "StrictSnapshotTest.a")

    #expect(throws: (any Error).self) {
      try store.registeredAccounts(for: .claude)
    }
  }

  @Test func providerScopedSnapshotIgnoresAnUnavailablePrefixedOtherProvider() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "ProviderSnapshotTest")
    try store.save(Self.account(id: "codex:broken", capturedAt: Date(timeIntervalSince1970: 100)))
    try store.save(CapturedAccount(
      id: "claude:available",
      provider: .claude,
      displayName: "Claude",
      detail: "Keychain",
      capturedAt: Date(timeIntervalSince1970: 200),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: Data(#"{"claudeAiOauth":{"accessToken":"access","refreshToken":"refresh"}}"#.utf8)
    ))
    keychain.failReads(of: "ProviderSnapshotTest.codex:broken")

    #expect(try store.registeredAccounts(for: .claude).map(\.id) == ["claude:available"])
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

  @Test func upsertFailsClosedWhenExistingAccountReadFails() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "UpsertReadTest")
    let existing = Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100), token: "fresh")
    try store.save(existing)
    keychain.failReads(of: "UpsertReadTest.a")

    #expect(throws: (any Error).self) {
      try store.upsert(
        Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 200), token: "stale")
      ) { current, _ in current }
    }

    keychain.stopFailing("UpsertReadTest.a")
    #expect(store.account(id: "a") == existing)
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

  @Test func claudePayloadAndTerminalIdentityRefreshAtomically() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "ClaudeMetadataUpdateTest")
    let account = CapturedAccount(
      id: "claude:a",
      provider: .claude,
      displayName: "Claude",
      detail: "Keychain",
      capturedAt: .distantPast,
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-ref"}}"#.utf8)
    )
    try store.save(account)
    let metadata = Data(#"{"accountUuid":"a","emailAddress":"a@example.com"}"#.utf8)
    let identity = ClaudeAccountIdentity(
      accountID: "account-a",
      email: "a@example.com",
      organizationID: "organization-a"
    )

    try store.updatePayload(
      id: account.id,
      claudeOAuthAccount: metadata,
      claudeAccountIdentity: identity
    ) { _ in
      Data(#"{"claudeAiOauth":{"accessToken":"new","refreshToken":"new-ref"}}"#.utf8)
    }

    let refreshed = try #require(store.account(id: account.id))
    #expect(refreshed.claudeOAuthAccount == metadata)
    #expect(refreshed.claudeAccountIdentity == identity)
    #expect(try ClaudeCredentialsStore.parse(refreshed.payload).accessToken == "new")
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

  @Test func pendingGrantSurvivesATransientAccountReadFailure() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "PendTest")
    try store.save(Self.account(id: "a", capturedAt: Date(timeIntervalSince1970: 100)))

    // Only a confirmed absence may skip the write — a read hiccup must not
    // drop the only fresh grant.
    keychain.failReads(of: "PendTest.a")
    try store.savePendingGrant(Data("pending".utf8), id: "a")
    keychain.stopFailing("PendTest.a")

    #expect(store.pendingGrantData(id: "a") == Data("pending".utf8))
  }

  @Test func livePendingGrantPreservesItsOwnerUntilAnExactDelete() throws {
    let store = makeStore(InMemoryKeychain())
    let id = "claude-live:test-source"
    let owner = Data("owner".utf8)
    let competitor = Data("competitor".utf8)

    #expect(try store.saveLivePendingGrantIfAbsent(owner, id: id))
    #expect(try store.saveLivePendingGrantIfAbsent(owner, id: id))
    #expect(try !store.saveLivePendingGrantIfAbsent(competitor, id: id))
    #expect(store.pendingGrantData(id: id) == owner)

    #expect(try !store.removePendingGrant(id: id, matching: competitor))
    #expect(store.pendingGrantData(id: id) == owner)
    #expect(try store.removePendingGrant(id: id, matching: owner))
    #expect(store.pendingGrantData(id: id) == nil)
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

struct CapturedAccountStoreAtomicUpsertTests {
  @Test func concurrentStrongIdentityUpsertsConvergeOnOneUUIDRow() async throws {
    let keychain = InMemoryKeychain()
    let service = "ConcurrentIdentityUpsertTest"
    let store = CapturedAccountStore(keychain: keychain.store, service: service)
    let identity = ClaudeAccountIdentity(
      accountID: "account",
      email: "user@example.com",
      organizationID: "organization"
    )
    let candidates = [
      claudeAccount(id: "claude:uuid-a", token: "token-a", identity: identity, capturedAt: 100),
      claudeAccount(id: "claude:uuid-b", token: "token-b", identity: identity, capturedAt: 200),
    ]

    let upserted = try await withThrowingTaskGroup(
      of: CapturedAccount.self,
      returning: [CapturedAccount].self
    ) { group in
      for candidate in candidates {
        group.addTask {
          try store.upsert(
            candidate,
            matchingExisting: matchesStrongClaudeIdentity
          ) { _, candidate in
            candidate
          }
        }
      }
      var results: [CapturedAccount] = []
      for try await result in group {
        results.append(result)
      }
      return results
    }

    let persisted = try #require(store.load().first)
    #expect(store.load().count == 1)
    #expect(Set(upserted.map(\.id)) == [persisted.id])
    #expect(["claude:uuid-a", "claude:uuid-b"].contains(persisted.id))
    #expect(keychain.writeCount(of: "\(service)-Index") == 1)
    let discardedID = persisted.id == "claude:uuid-a" ? "claude:uuid-b" : "claude:uuid-a"
    #expect(!keychain.hasItem("\(service).\(discardedID)"))
  }

  @Test func ambiguousStrongIdentityUpsertLeavesRowsPayloadsAndIndexUntouched() throws {
    let keychain = InMemoryKeychain()
    let service = "AmbiguousIdentityUpsertTest"
    let store = CapturedAccountStore(keychain: keychain.store, service: service)
    let identity = ClaudeAccountIdentity(
      accountID: "account",
      email: "user@example.com",
      organizationID: "organization"
    )
    let first = claudeAccount(id: "claude:uuid-a", token: "token-a", identity: identity, capturedAt: 100)
    let second = claudeAccount(id: "claude:uuid-b", token: "token-b", identity: identity, capturedAt: 200)
    try store.save(first)
    try store.save(second)

    let indexService = "\(service)-Index"
    let firstService = "\(service).\(first.id)"
    let secondService = "\(service).\(second.id)"
    let candidateService = "\(service).claude:uuid-c"
    let originalIndex = try #require(try keychain.read(indexService))
    let originalFirst = try #require(try keychain.read(firstService))
    let originalSecond = try #require(try keychain.read(secondService))
    let originalAccounts = store.load()
    let originalServiceCount = keychain.serviceCount
    let originalWriteCounts = [
      indexService: keychain.writeCount(of: indexService),
      firstService: keychain.writeCount(of: firstService),
      secondService: keychain.writeCount(of: secondService),
    ]
    let candidate = claudeAccount(
      id: "claude:uuid-c",
      token: "candidate-token",
      identity: identity,
      capturedAt: 300
    )

    #expect(throws: CapturedAccountStoreError.ambiguousIdentity) {
      try store.upsert(
        candidate,
        matchingExisting: matchesStrongClaudeIdentity
      ) { _, candidate in
        candidate
      }
    }

    #expect(try keychain.read(indexService) == originalIndex)
    #expect(try keychain.read(firstService) == originalFirst)
    #expect(try keychain.read(secondService) == originalSecond)
    #expect(!keychain.hasItem(candidateService))
    #expect(store.load() == originalAccounts)
    #expect(keychain.serviceCount == originalServiceCount)
    #expect(keychain.writeCount(of: indexService) == originalWriteCounts[indexService])
    #expect(keychain.writeCount(of: firstService) == originalWriteCounts[firstService])
    #expect(keychain.writeCount(of: secondService) == originalWriteCounts[secondService])
    #expect(keychain.writeCount(of: candidateService) == 0)
  }
}

private func claudeAccount(
  id: String,
  token: String,
  identity: ClaudeAccountIdentity,
  capturedAt: TimeInterval
) -> CapturedAccount {
  CapturedAccount(
    id: id,
    provider: .claude,
    displayName: "Claude",
    detail: "Keychain",
    capturedAt: Date(timeIntervalSince1970: capturedAt),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"shared-refresh"}}"#.utf8),
    claudeAccountIdentity: identity
  )
}

private func matchesStrongClaudeIdentity(
  _ existing: CapturedAccount,
  _ candidate: CapturedAccount
) -> Bool {
  guard let existingIdentity = existing.claudeAccountIdentity,
        existingIdentity.isStrong,
        let candidateIdentity = candidate.claudeAccountIdentity,
        candidateIdentity.isStrong
  else { return false }
  return existingIdentity.identifiesSameAccount(as: candidateIdentity)
}
