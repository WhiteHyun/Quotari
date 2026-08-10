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
  /// Token-independent identity verified from Claude's profile endpoint.
  /// Optional for backward compatibility with legacy token-keyed rows.
  public var claudeAccountIdentity: ClaudeAccountIdentity?

  public init(
    id: String,
    provider: UsageProvider,
    displayName: String,
    detail: String?,
    capturedAt: Date,
    origin: ProviderCredentialSource,
    payload: Data,
    claudeOAuthAccount: Data? = nil,
    claudeAccountIdentity: ClaudeAccountIdentity? = nil
  ) {
    self.id = id
    self.provider = provider
    self.displayName = displayName
    self.detail = detail
    self.capturedAt = capturedAt
    self.origin = origin
    self.payload = payload
    self.claudeOAuthAccount = claudeOAuthAccount
    self.claudeAccountIdentity = claudeAccountIdentity
  }
}

public enum CapturedAccountStoreError: LocalizedError, Equatable, Sendable {
  case ambiguousIdentity
  case conflictingClaudeIdentity

  public var errorDescription: String? {
    switch self {
    case .ambiguousIdentity:
      "Multiple saved accounts match the same verified identity. No account was changed."
    case .conflictingClaudeIdentity:
      "The saved account has a different verified Claude identity. No account was changed."
    }
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
  static let mutationLock = NSLock()

  let keychain: KeychainItemStore
  private let itemPrefix: String
  private let indexService: String

  public init(
    keychain: KeychainItemStore = .appOwned(),
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
      try registeredAccountsUnlocked(for: provider)
    }
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
      // An explicit same-id save is also the recovery path for a readable but
      // corrupt item. Identity-based upserts remain strict and ambiguous rows
      // still fail closed before reaching this write.
      try keychain.write(encode(account), service: itemService(account.id))
    }
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
    try upsert(candidate, matchingExisting: { _, _ in false }, mergingExisting: merge)
  }

  /// Atomically finds a row by immutable account identity and writes the new
  /// credential generation into that row. The winning existing id is retained
  /// even when `candidate` was created with a fresh local UUID.
  @discardableResult
  public func upsert(
    _ candidate: CapturedAccount,
    matchingExisting matches: (CapturedAccount, CapturedAccount) throws -> Bool,
    mergingExisting merge: (CapturedAccount, CapturedAccount) throws -> CapturedAccount
  ) throws -> CapturedAccount {
    try Self.mutationLock.withLock {
      let candidates = try registeredAccountsUnlocked(for: candidate.provider).filter {
        if $0.id == candidate.id {
          return true
        }
        return try matches($0, candidate)
      }
      guard candidates.count <= 1 else {
        throw CapturedAccountStoreError.ambiguousIdentity
      }
      let existing = candidates.first
      var insert = candidate
      if let existing {
        insert.id = existing.id
      }
      var resolved = try existing.map { try merge($0, insert) } ?? insert
      if let existing {
        resolved.id = existing.id
        resolved.provider = existing.provider
      }
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
    try updatePayload(
      id: id,
      claudeOAuthAccount: nil,
      claudeAccountIdentity: nil,
      transform: transform
    )
  }

  public func updatePayload(
    id: String,
    claudeOAuthAccount: Data?,
    claudeAccountIdentity: ClaudeAccountIdentity? = nil,
    transform: (Data) throws -> Data
  ) throws {
    try Self.mutationLock.withLock {
      guard var account = try loadAccount(id: id) else {
        throw KeychainItemStore.KeychainError.commandFailed(status: 44)
      }
      account.payload = try transform(account.payload)
      if account.provider == .claude, let claudeOAuthAccount {
        account.claudeOAuthAccount = claudeOAuthAccount
      }
      if account.provider == .claude, let claudeAccountIdentity {
        if let stored = account.claudeAccountIdentity {
          guard let merged = stored.merged(with: claudeAccountIdentity) else {
            throw CapturedAccountStoreError.conflictingClaudeIdentity
          }
          account.claudeAccountIdentity = merged
        } else {
          account.claudeAccountIdentity = claudeAccountIdentity
        }
      }
      try keychain.write(encode(account), service: itemService(id))
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

  /// Strictly reads provider rows and repairs only confirmed dangling index
  /// entries. This lets a UUID-based insert retry after an account-item write
  /// failure without treating a keychain read error as absence.
  private func registeredAccountsUnlocked(for provider: UsageProvider) throws -> [CapturedAccount] {
    let ids = try indexIDs() ?? []
    var danglingIDs = Set<String>()
    var accounts: [CapturedAccount] = []
    for id in ids {
      if let indexedProvider = Self.provider(encodedIn: id), indexedProvider != provider {
        continue
      }
      guard let data = try keychain.read(service: itemService(id)) else {
        danglingIDs.insert(id)
        continue
      }
      guard let account = try? JSONDecoder().decode(CapturedAccount.self, from: data) else {
        throw RegisteredAccountReadError.unavailable(id)
      }
      if account.provider == provider {
        accounts.append(account)
      }
    }
    if !danglingIDs.isEmpty {
      let repaired = ids.filter { !danglingIDs.contains($0) }
      if repaired.isEmpty {
        try keychain.delete(service: indexService)
      } else {
        try writeIndex(repaired)
      }
    }
    return accounts
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

  func itemService(_ id: String) -> String {
    "\(itemPrefix).\(id)"
  }

  func pendingService(_ id: String) -> String {
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
