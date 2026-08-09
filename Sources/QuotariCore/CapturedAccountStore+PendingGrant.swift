import Foundation

public extension CapturedAccountStore {
  /// Durable copy of a grant whose account-item write failed, so quitting
  /// before the retry doesn't lose the only rotated pair. The account's
  /// removal cleans up this separate Keychain item.
  func savePendingGrant(_ data: Data, id: String) throws {
    try Self.mutationLock.withLock {
      do {
        guard try keychain.read(service: itemService(id)) != nil else { return }
      } catch {}
      try keychain.write(data, service: pendingService(id))
    }
  }

  /// Safety-critical read that distinguishes absence from a Keychain fault.
  func loadPendingGrantData(id: String) throws -> Data? {
    try keychain.read(service: pendingService(id))
  }

  /// Installs a recovery grant only when no different recovery is already in
  /// flight for the account.
  @discardableResult
  func savePendingGrantIfAbsent(_ data: Data, id: String) throws -> Bool {
    try Self.mutationLock.withLock {
      if let current = try keychain.read(service: pendingService(id)) {
        return current == data
      }
      guard try keychain.read(service: itemService(id)) != nil else { return false }
      try keychain.write(data, service: pendingService(id))
      return true
    }
  }

  /// Installs recovery data for a live credential source that has no captured
  /// account item to anchor it.
  @discardableResult
  internal func saveLivePendingGrantIfAbsent(_ data: Data, id: String) throws -> Bool {
    try Self.mutationLock.withLock {
      if let current = try keychain.read(service: pendingService(id)) {
        return current == data
      }
      try keychain.write(data, service: pendingService(id))
      return true
    }
  }

  /// Compare-and-delete for a recovery that was previously read or created.
  @discardableResult
  func removePendingGrant(id: String, matching expected: Data) throws -> Bool {
    try Self.mutationLock.withLock {
      guard let current = try keychain.read(service: pendingService(id)), current == expected else {
        return false
      }
      try keychain.delete(service: pendingService(id))
      return true
    }
  }

  /// Typed comparison avoids depending on JSON object key order.
  @discardableResult
  func removePendingGrant(
    id: String,
    when matches: (Data) throws -> Bool
  ) throws -> Bool {
    try Self.mutationLock.withLock {
      guard let current = try keychain.read(service: pendingService(id)), try matches(current) else {
        return false
      }
      try keychain.delete(service: pendingService(id))
      return true
    }
  }

  /// Compare-and-replace for recovery metadata that advances with the same
  /// grant; a concurrent owner wins over the stale snapshot.
  @discardableResult
  internal func replacePendingGrant(
    id: String,
    when matches: (Data) throws -> Bool,
    with replacement: Data
  ) throws -> Bool {
    try Self.mutationLock.withLock {
      guard let current = try keychain.read(service: pendingService(id)), try matches(current) else {
        return false
      }
      try keychain.write(replacement, service: pendingService(id))
      return true
    }
  }
}
