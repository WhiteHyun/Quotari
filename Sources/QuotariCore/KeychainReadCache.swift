import Foundation

/// Short-lived read cache for Quotari-owned keychain items.
///
/// Every `SecItemCopyMatching` against the file-based login keychain leaves
/// untagged VM regions behind in the calling process (about one per seven
/// reads on macOS 15), and a refresh cycle re-reads the registry index and
/// every captured account from many call sites. Those reads added gigabytes
/// over days. Quotari is the only writer of these items (see
/// `CapturedAccountStore.mutationLock`), so writes and deletes update the
/// cache directly; the lifetime only bounds how long an edit made outside
/// this process can stay unseen.
final class KeychainReadCache: @unchecked Sendable {
  static let shared = KeychainReadCache(lifetime: 15)

  private struct Key: Hashable {
    let account: String
    let service: String
  }

  private struct Entry {
    let data: Data?
    let storedAt: Date
  }

  private let lifetime: TimeInterval
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]
  /// Bumped by every write, so a read that started before it cannot cache
  /// the value it loaded from the keychain over the newer one.
  private var generations: [Key: UInt64] = [:]

  init(lifetime: TimeInterval, now: @escaping @Sendable () -> Date = Date.init) {
    self.lifetime = lifetime
    self.now = now
  }

  func read(account: String, service: String, load: () throws -> Data?) throws -> Data? {
    let key = Key(account: account, service: service)
    let (cached, generation) = lock.withLock { () -> (Entry?, UInt64) in
      (entries[key], generations[key, default: 0])
    }
    let currentTime = now()
    if let cached, currentTime >= cached.storedAt, currentTime.timeIntervalSince(cached.storedAt) < lifetime {
      return cached.data
    }
    let data = try load()
    lock.withLock {
      guard generations[key, default: 0] == generation else { return }
      entries[key] = Entry(data: data, storedAt: currentTime)
    }
    return data
  }

  func store(_ data: Data?, account: String, service: String) {
    let key = Key(account: account, service: service)
    let storedAt = now()
    lock.withLock {
      generations[key, default: 0] &+= 1
      entries[key] = Entry(data: data, storedAt: storedAt)
    }
  }

  /// For a write whose outcome is unknown: the next read goes to the keychain.
  func invalidate(account: String, service: String) {
    let key = Key(account: account, service: service)
    lock.withLock {
      generations[key, default: 0] &+= 1
      entries[key] = nil
    }
  }
}
