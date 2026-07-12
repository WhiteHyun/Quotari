import Foundation

/// A provider credential snapshot Quotari captured and now owns, so a second
/// account survives even after the CLI's own credential slot is overwritten
/// by a different login. The raw payload is a minimal provider-specific
/// credential document (only the fields Quotari reads), so the existing
/// credential parsers read it back unchanged without carrying unrelated
/// secrets from the source.
public struct CapturedAccount: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var provider: UsageProvider
  public var displayName: String
  public var detail: String?
  public var capturedAt: Date
  /// The originating source, recorded so a re-capture can find and refresh
  /// this snapshot when the CLI's live credential changes.
  public var origin: ProviderCredentialSource
  public var payload: Data

  public init(
    id: String,
    provider: UsageProvider,
    displayName: String,
    detail: String?,
    capturedAt: Date,
    origin: ProviderCredentialSource,
    payload: Data
  ) {
    self.id = id
    self.provider = provider
    self.displayName = displayName
    self.detail = detail
    self.capturedAt = capturedAt
    self.origin = origin
    self.payload = payload
  }
}

/// Persists captured account snapshots in Quotari-owned keychain items. Each
/// account is its own item (`Quotari-Captured-Account.<id>`) so a token
/// refresh rewrites only that account, never a shared blob — two accounts
/// refreshing concurrently can't clobber each other. A separate index item
/// holds just the ordered list of ids (no secrets). Reads that back the
/// destructive index update fail closed, so a transient keychain failure
/// can't truncate the registry.
public struct CapturedAccountStore: Sendable {
  public static let itemPrefix = "Quotari-Captured-Account"
  public static let indexService = "Quotari-Captured-Accounts-Index"

  /// Serializes every registry mutation process-wide. The operations run off
  /// the main actor (detached) and touch a shared index item, so without this
  /// two concurrent captures could each read the index and drop the other's
  /// id, and a refresh could race a removal. Quotari owns these items, so a
  /// process-local lock is the whole scope of contention.
  private static let mutationLock = NSLock()

  private let keychain: KeychainItemStore
  private let itemPrefix: String
  private let indexService: String

  public init(
    keychain: KeychainItemStore = KeychainItemStore(),
    itemPrefix: String = CapturedAccountStore.itemPrefix,
    indexService: String = CapturedAccountStore.indexService
  ) {
    self.keychain = keychain
    self.itemPrefix = itemPrefix
    self.indexService = indexService
  }

  /// Backward/overload convenience so existing call sites that passed a single
  /// `service:` keep working: derive both namespaces from it.
  public init(keychain: KeychainItemStore, service: String) {
    self.init(keychain: keychain, itemPrefix: service, indexService: "\(service)-Index")
  }

  /// Best-effort listing for the UI: skips any entry whose item can't be read
  /// or decoded rather than failing, and never rewrites anything.
  public func load() -> [CapturedAccount] {
    guard let ids = try? indexIDs() else { return [] }
    return ids
      .compactMap { account(id: $0) }
      .sorted { $0.capturedAt < $1.capturedAt }
  }

  public func account(id: String) -> CapturedAccount? {
    guard let data = keychain.readOptional(service: itemService(id)),
          let account = try? JSONDecoder().decode(CapturedAccount.self, from: data)
    else { return nil }
    return account
  }

  /// Capture (or re-capture): registers the id in the index first, then writes
  /// the account's own item. That ordering means a fault between the two steps
  /// leaves at worst a dangling id (load() skips it) rather than an orphaned
  /// secret with no index entry. The index read fails closed, so a transient
  /// read failure throws instead of writing a truncated index.
  public func save(_ account: CapturedAccount) throws {
    try Self.mutationLock.withLock {
      var ids = try indexIDs() ?? []
      if !ids.contains(account.id) {
        ids.append(account.id)
        try writeIndex(ids)
      }
      try keychain.write(encode(account), service: itemService(account.id))
    }
  }

  /// Refresh path: overwrites only the account's own item, never the index,
  /// so concurrent refreshes of different accounts don't contend on the index.
  public func updatePayload(id: String, payload: Data) throws {
    try Self.mutationLock.withLock {
      guard var account = account(id: id) else {
        throw KeychainItemStore.KeychainError.commandFailed(status: 44)
      }
      account.payload = payload
      try keychain.write(encode(account), service: itemService(id))
    }
  }

  /// Deletes the account item first, then drops its id from the index; a fault
  /// between the two leaves a dangling id, never an orphaned secret.
  public func remove(id: String) throws {
    try Self.mutationLock.withLock {
      try keychain.delete(service: itemService(id))
      var ids = try indexIDs() ?? []
      ids.removeAll { $0 == id }
      if ids.isEmpty {
        try keychain.delete(service: indexService)
      } else {
        try writeIndex(ids)
      }
    }
  }

  private func indexIDs() throws -> [String]? {
    guard let data = try keychain.read(service: indexService) else { return nil }
    return try JSONDecoder().decode(Index.self, from: data).ids
  }

  private func writeIndex(_ ids: [String]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try keychain.write(encoder.encode(Index(ids: ids)), service: indexService)
  }

  private func encode(_ account: CapturedAccount) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(account)
  }

  private func itemService(_ id: String) -> String {
    "\(itemPrefix).\(id)"
  }

  private struct Index: Codable {
    var ids: [String]
  }
}
