import Foundation

extension CodexUsageStrategy {
  /// Memory first (cheap), then the durable copy a previous launch left.
  /// The durable copy is deliberately NOT consumed here: it holds the only
  /// rotated pair, so it stays until the registry write succeeds (persisted
  /// clears it) or the grant is proven obsolete (the stale-write resolution
  /// clears it) — a crash mid-retry must not lose it.
  func loadDurablePending(registryID: String) throws -> CodexPendingGrant? {
    guard let data = try capturedAccounts.loadPendingGrantData(id: registryID) else { return nil }
    do {
      return try JSONDecoder().decode(CodexPendingGrant.self, from: data)
    } catch {
      throw CodexCredentialPersistError.malformedPayload
    }
  }

  func takePending(
    registryID: String,
    durablePending: CodexPendingGrant?
  ) async -> CodexPendingGrant? {
    if let pending = await refreshCoordinator.takeUnpersisted(registryID: registryID) {
      return pending
    }
    return durablePending
  }

  /// Queues in memory and, best-effort, durably — so quitting before the
  /// next fetch doesn't lose the only rotated pair.
  @discardableResult
  func rememberPending(_ pending: CodexPendingGrant, registryID: String) async -> Bool {
    await refreshCoordinator.rememberUnpersisted(pending, registryID: registryID)
    guard let data = try? JSONEncoder().encode(pending) else { return false }
    try? capturedAccounts.savePendingGrant(data, id: registryID)
    guard let saved = try? capturedAccounts.loadPendingGrantData(id: registryID),
          let decoded = try? JSONDecoder().decode(CodexPendingGrant.self, from: saved)
    else { return false }
    return decoded == pending
  }

  func removePendingIfMatching(_ pending: CodexPendingGrant, registryID: String) {
    _ = try? capturedAccounts.removePendingGrant(id: registryID) { data in
      (try? JSONDecoder().decode(CodexPendingGrant.self, from: data)) == pending
    }
  }

  /// The credentials patched with a grant that isn't (or isn't yet) stored —
  /// good for fetching with while the registry catches up.
  func inMemory(_ credentials: CodexCredentials, _ grant: CodexTokenGrant) -> CodexCredentials {
    var updated = credentials
    updated.accessToken = grant.accessToken
    updated.refreshToken = grant.refreshToken ?? credentials.refreshToken
    updated.expiresAt = CodexCredentialsStore.jwtExpiry(of: grant.accessToken)
    return updated
  }

  func reloadedFromRegistry(id: String, now: Date) -> CodexCredentials? {
    guard let reloaded = try? CodexCredentialsStore.load(
      source: .quotariRegistry(id: id),
      capturedAccounts: capturedAccounts
    ), !reloaded.isExpired(now: now)
    else { return nil }
    return reloaded
  }
}
