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
  /// Claude Code keeps the display identity used by `claude auth status` in a
  /// separate `~/.claude.json.oauthAccount` object. Store the exact object
  /// with the renewable credential so both can be restored together.
  public var claudeOAuthAccount: Data?

  public init(
    id: String,
    provider: UsageProvider,
    displayName: String,
    detail: String?,
    capturedAt: Date,
    origin: ProviderCredentialSource,
    payload: Data,
    claudeOAuthAccount: Data? = nil
  ) {
    self.id = id
    self.provider = provider
    self.displayName = displayName
    self.detail = detail
    self.capturedAt = capturedAt
    self.origin = origin
    self.payload = payload
    self.claudeOAuthAccount = claudeOAuthAccount
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
    try? loadAccount(id: id)
  }

  /// Strictly reads the requested provider while allowing an explicitly
  /// provider-prefixed row from another provider to remain unavailable. Legacy
  /// unprefixed ids are still read fail-closed because their provider cannot be
  /// established without decoding the row.
  public func registeredAccounts(for provider: UsageProvider) throws -> [CapturedAccount] {
    try Self.mutationLock.withLock {
      try (indexIDs() ?? []).compactMap { id in
        if let indexedProvider = Self.provider(encodedIn: id), indexedProvider != provider {
          return nil
        }
        let account = try strictlyLoadRegisteredAccount(id: id)
        return account.provider == provider ? account : nil
      }
    }
  }

  /// Capture (or re-capture): registers the id in the index first, then writes
  /// the account's own item. That ordering means a fault between the two steps
  /// leaves at worst a dangling id (load() skips it) rather than an orphaned
  /// secret with no index entry. The index read fails closed, so a transient
  /// read failure throws instead of writing a truncated index.
  public func save(_ account: CapturedAccount) throws {
    _ = try upsert(account) { _, candidate in candidate }
  }

  /// Atomically inserts `candidate`, or lets the caller merge it with the
  /// current row when the identity is already registered. Keeping the read,
  /// conflict decision, and write under one mutation lock prevents a stale CLI
  /// snapshot from winning a check-then-save race with a token refresh.
  @discardableResult
  public func upsert(
    _ candidate: CapturedAccount,
    mergingExisting merge: (CapturedAccount, CapturedAccount) throws -> CapturedAccount
  ) throws -> CapturedAccount {
    try Self.mutationLock.withLock {
      // The public best-effort lookup intentionally hides keychain failures
      // for UI reads, but doing that here could let a stale candidate overwrite
      // a fresher stored refresh-token pair without invoking `merge`.
      let existing = try loadAccount(id: candidate.id)
      let resolved = try existing.map { try merge($0, candidate) } ?? candidate
      var ids = try indexIDs() ?? []
      if !ids.contains(resolved.id) {
        ids.append(resolved.id)
        try writeIndex(ids)
      }
      try keychain.write(encode(resolved), service: itemService(resolved.id))
      return resolved
    }
  }

  /// Refresh path: overwrites only the account's own item, never the index,
  /// so concurrent refreshes of different accounts don't contend on the index.
  /// `transform` runs under the mutation lock on the freshly read payload, so
  /// a check-then-write (e.g. a stale-token guard) can't race a concurrent
  /// capture or refresh into clobbering the newer pair.
  public func updatePayload(id: String, transform: (Data) throws -> Data) throws {
    try updatePayload(id: id, claudeOAuthAccount: nil, transform: transform)
  }

  public func updatePayload(
    id: String,
    claudeOAuthAccount: Data?,
    transform: (Data) throws -> Data
  ) throws {
    try Self.mutationLock.withLock {
      guard var account = account(id: id) else {
        throw KeychainItemStore.KeychainError.commandFailed(status: 44)
      }
      account.payload = try transform(account.payload)
      if account.provider == .claude, let claudeOAuthAccount {
        account.claudeOAuthAccount = claudeOAuthAccount
      }
      try keychain.write(encode(account), service: itemService(id))
    }
  }

  /// Durable copy of a grant whose account-item write failed, so quitting
  /// before the retry doesn't lose the only rotated pair. Its own keychain
  /// item (never a file — secrets stay in the keychain), outside the index;
  /// the account's removal cleans it up. Serialized with removal and gated
  /// on the account still existing, so an in-flight refresh can't recreate
  /// a pending blob for an account the user just removed.
  public func savePendingGrant(_ data: Data, id: String) throws {
    try Self.mutationLock.withLock {
      do {
        // Only a confirmed absence (a removed account) skips the write; a
        // transient read failure must not drop the only fresh grant.
        guard try keychain.read(service: itemService(id)) != nil else { return }
      } catch {}
      try keychain.write(data, service: pendingService(id))
    }
  }

  public func pendingGrantData(id: String) -> Data? {
    try? loadPendingGrantData(id: id)
  }

  /// Safety-critical pending-grant read. Unlike `pendingGrantData`, this
  /// distinguishes a missing item from a keychain failure so a caller never
  /// falls back to an older, already-consumed credential pair by accident.
  public func loadPendingGrantData(id: String) throws -> Data? {
    try keychain.read(service: pendingService(id))
  }

  public func removePendingGrant(id: String) throws {
    try Self.mutationLock.withLock {
      try keychain.delete(service: pendingService(id))
    }
  }

  /// Installs a recovery grant only when no different recovery is already in
  /// flight for the account. A linked live refresh must never overwrite an
  /// unrelated saved-account rotation that owns the same pending slot.
  @discardableResult
  public func savePendingGrantIfAbsent(_ data: Data, id: String) throws -> Bool {
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
  /// account item to anchor it. The caller owns the namespaced id and must
  /// compare-and-delete the item after the source accepts the grant or moves
  /// to another login. Keeping this separate from `savePendingGrantIfAbsent`
  /// preserves the latter's removal guard for user-managed saved accounts.
  @discardableResult
  func saveLivePendingGrantIfAbsent(_ data: Data, id: String) throws -> Bool {
    try Self.mutationLock.withLock {
      if let current = try keychain.read(service: pendingService(id)) {
        return current == data
      }
      try keychain.write(data, service: pendingService(id))
      return true
    }
  }

  /// Compare-and-delete for a recovery that was previously read or created.
  /// A newer concurrent pending grant survives instead of being mistaken for
  /// the one this caller just resolved.
  @discardableResult
  public func removePendingGrant(id: String, matching expected: Data) throws -> Bool {
    try Self.mutationLock.withLock {
      guard let current = try keychain.read(service: pendingService(id)), current == expected else {
        return false
      }
      try keychain.delete(service: pendingService(id))
      return true
    }
  }

  /// Typed callers can compare decoded grants atomically. JSON object key
  /// ordering is not stable across encoders or app versions, so safety-
  /// critical compare-and-delete must not depend only on byte equality.
  @discardableResult
  public func removePendingGrant(
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

  /// Compare-and-replace for a recovery item whose metadata advances while
  /// retaining the same grant. A concurrent owner wins instead of being
  /// overwritten by a stale account-switch snapshot.
  @discardableResult
  func replacePendingGrant(
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

  /// Deletes the account item first, then drops its id from the index; a fault
  /// between the two leaves a dangling id, never an orphaned secret.
  public func remove(id: String) throws {
    try Self.mutationLock.withLock {
      // Pending grant first, and fail closed: aborting the removal beats
      // reporting success while a token blob is left behind with no UI
      // path to clean it up. ("Not found" already counts as deleted.)
      try keychain.delete(service: pendingService(id))
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

  private func loadAccount(id: String) throws -> CapturedAccount? {
    guard let data = try keychain.read(service: itemService(id)) else { return nil }
    // A successfully read but corrupt entry remains recoverable by a later
    // valid capture, matching the registry's best-effort listing contract.
    // Only the keychain read itself must fail closed.
    return try? JSONDecoder().decode(CapturedAccount.self, from: data)
  }

  private func strictlyLoadRegisteredAccount(id: String) throws -> CapturedAccount {
    guard let data = try keychain.read(service: itemService(id)),
          let account = try? JSONDecoder().decode(CapturedAccount.self, from: data)
    else {
      throw RegisteredAccountReadError.unavailable(id)
    }
    return account
  }

  private func writeIndex(_ ids: [String]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try keychain.write(encoder.encode(Index(ids: ids)), service: indexService)
  }

  private static func provider(encodedIn id: String) -> UsageProvider? {
    UsageProvider.allCases.first { id.hasPrefix("\($0.rawValue):") }
  }

  private func encode(_ account: CapturedAccount) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(account)
  }

  private func itemService(_ id: String) -> String {
    "\(itemPrefix).\(id)"
  }

  private func pendingService(_ id: String) -> String {
    "\(itemPrefix).pending.\(id)"
  }

  private struct Index: Codable {
    var ids: [String]
  }

  private enum RegisteredAccountReadError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
      switch self {
      case let .unavailable(id):
        "The saved account registry entry \(id) could not be read safely."
      }
    }
  }
}
