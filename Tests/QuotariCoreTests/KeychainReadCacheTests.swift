import Foundation
@testable import QuotariCore
import Security
import Testing

struct KeychainReadCacheTests {
  @Test func repeatedReadsWithinTheLifetimeHitTheKeychainOnce() throws {
    let fake = CountingSecurityKeychain()
    fake.items["index"] = Data("ids".utf8)
    let clock = ReadCacheClock()
    let store = fake.store(cache: KeychainReadCache(lifetime: 15, now: clock.now))

    for _ in 0 ..< 20 {
      #expect(try store.read(service: "index") == Data("ids".utf8))
    }

    #expect(fake.copyCount == 1)
  }

  @Test func absenceIsCachedToo() throws {
    let fake = CountingSecurityKeychain()
    let store = fake.store(cache: KeychainReadCache(lifetime: 15, now: ReadCacheClock().now))

    #expect(try store.read(service: "pending") == nil)
    #expect(try store.read(service: "pending") == nil)

    #expect(fake.copyCount == 1)
  }

  @Test func writesAndDeletesAreVisibleImmediatelyWithoutRereading() throws {
    let fake = CountingSecurityKeychain()
    fake.items["account"] = Data("old".utf8)
    let store = fake.store(cache: KeychainReadCache(lifetime: 15, now: ReadCacheClock().now))
    _ = try store.read(service: "account")

    try store.write(Data("new".utf8), service: "account")
    #expect(try store.read(service: "account") == Data("new".utf8))
    try store.delete(service: "account")
    #expect(try store.read(service: "account") == nil)

    #expect(fake.copyCount == 1)
  }

  @Test func externalEditsAreSeenAfterTheLifetime() throws {
    let fake = CountingSecurityKeychain()
    fake.items["account"] = Data("old".utf8)
    let clock = ReadCacheClock()
    let store = fake.store(cache: KeychainReadCache(lifetime: 15, now: clock.now))
    _ = try store.read(service: "account")
    fake.items["account"] = Data("edited elsewhere".utf8)

    clock.advance(by: 10)
    #expect(try store.read(service: "account") == Data("old".utf8))
    clock.advance(by: 6)
    #expect(try store.read(service: "account") == Data("edited elsewhere".utf8))
  }

  @Test func failedReadsAreNotCached() throws {
    let fake = CountingSecurityKeychain()
    fake.items["account"] = Data("value".utf8)
    fake.copyStatusOverride = errSecInteractionNotAllowed
    let store = fake.store(cache: KeychainReadCache(lifetime: 15, now: ReadCacheClock().now))

    #expect(throws: KeychainItemStore.KeychainError.self) { try store.read(service: "account") }
    fake.copyStatusOverride = nil
    #expect(try store.read(service: "account") == Data("value".utf8))
  }

  @Test func failedWriteDropsTheCachedValue() throws {
    let fake = CountingSecurityKeychain()
    fake.items["account"] = Data("value".utf8)
    let store = fake.store(cache: KeychainReadCache(lifetime: 15, now: ReadCacheClock().now))
    _ = try store.read(service: "account")
    fake.writeStatusOverride = errSecIO

    #expect(throws: KeychainItemStore.KeychainError.self) {
      try store.write(Data("lost".utf8), service: "account")
    }
    _ = try store.read(service: "account")

    #expect(fake.copyCount == 2)
  }

  @Test func readThatStartedBeforeAWriteDoesNotOverwriteTheWrittenValue() throws {
    let cache = KeychainReadCache(lifetime: 15, now: ReadCacheClock().now)

    let stale = try cache.read(account: "user", service: "account") {
      cache.store(Data("new".utf8), account: "user", service: "account")
      return Data("old".utf8)
    }
    let current = try cache.read(account: "user", service: "account") {
      Issue.record("Expected the written value to be served from the cache")
      return nil
    }

    #expect(stale == Data("old".utf8))
    #expect(current == Data("new".utf8))
  }
}

private final class ReadCacheClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_000_000)

  var now: @Sendable () -> Date {
    { [self] in lock.withLock { current } }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { current += interval }
  }
}

private final class CountingSecurityKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Data] = [:]
  private var copies = 0
  private var copyOverride: OSStatus?
  private var writeOverride: OSStatus?

  var items: [String: Data] {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }

  var copyCount: Int {
    lock.withLock { copies }
  }

  var copyStatusOverride: OSStatus? {
    get { lock.withLock { copyOverride } }
    set { lock.withLock { copyOverride = newValue } }
  }

  var writeStatusOverride: OSStatus? {
    get { lock.withLock { writeOverride } }
    set { lock.withLock { writeOverride = newValue } }
  }

  func store(cache: KeychainReadCache) -> KeychainItemStore {
    KeychainItemStore.appOwned(
      account: "user",
      keychain: SecurityFrameworkKeychainStore(operations: operations),
      cache: cache
    )
  }

  private var operations: KeychainSecurityOperations {
    KeychainSecurityOperations(
      copyMatching: { query, result in
        self.lock.withLock {
          self.copies += 1
          if let status = self.copyOverride {
            return status
          }
          guard let data = self.storage[Self.service(query)] else { return errSecItemNotFound }
          result?.pointee = data as CFData
          return errSecSuccess
        }
      },
      update: { query, attributes in
        self.lock.withLock {
          if let status = self.writeOverride {
            return status
          }
          let service = Self.service(query)
          guard self.storage[service] != nil else { return errSecItemNotFound }
          self.storage[service] = (attributes as NSDictionary)[kSecValueData as String] as? Data
          return errSecSuccess
        }
      },
      add: { attributes, _ in
        self.lock.withLock {
          if let status = self.writeOverride {
            return status
          }
          self.storage[Self.service(attributes)] = (attributes as NSDictionary)[kSecValueData as String] as? Data
          return errSecSuccess
        }
      },
      delete: { query in
        self.lock.withLock {
          self.storage[Self.service(query)] = nil
          return errSecSuccess
        }
      }
    )
  }

  private static func service(_ query: CFDictionary) -> String {
    (query as NSDictionary)[kSecAttrService as String] as? String ?? ""
  }
}
