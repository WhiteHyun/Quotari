import Foundation

extension ClaudeUsageStrategy {
  enum DurablePendingSlot {
    case capturedAccount(String)
    case liveSource(String)

    var id: String {
      switch self {
      case let .capturedAccount(id), let .liveSource(id): id
      }
    }
  }

  /// A cached A -> B proof must reach the saved row before B can be consumed
  /// by another exchange. A queued-but-not-applied bridge also blocks: B -> C
  /// would otherwise leave only B durable after the app exits.
  func cachedMirrorBlocksRefresh(
    _ resolved: ResolvedClaudeCredentials,
    registryID: String
  ) async -> Bool {
    guard let acceptedGrant = await refreshCoordinator.acceptedGrant(
      sourceID: resolved.source.stableID,
      accessToken: resolved.credentials.accessToken,
      refreshToken: resolved.credentials.refreshToken
    ) else { return false }
    return mirrorAcceptedGrant(acceptedGrant, to: registryID) == .blocked
  }

  /// Repairs a linked registry write that failed after the live source had
  /// already accepted a rotating grant. This runs before the live token's
  /// expiry gate so a fresh keychain pair does not postpone recovery.
  func recoverLinkedRegistryGrant(id: String) throws {
    guard let data = try capturedAccounts.loadPendingGrantData(id: id) else { return }
    let pending: ClaudePendingGrant
    do {
      pending = try JSONDecoder().decode(ClaudePendingGrant.self, from: data)
    } catch {
      throw ClaudeCredentialPersistError.malformedPayload
    }
    let stored = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: id),
      capturedAccounts: capturedAccounts
    )
    if pending.matchesInstalledGeneration(
      accessToken: stored.accessToken,
      refreshToken: stored.refreshToken
    ) {
      _ = try capturedAccounts.removePendingGrant(id: id, matching: data)
      return
    }
    guard pending.supersedes(
      accessToken: stored.accessToken,
      refreshToken: stored.refreshToken
    )
    else {
      // A different login/generation owns the row now. The linked grant is
      // obsolete and must never be retried over it.
      _ = try capturedAccounts.removePendingGrant(id: id, matching: data)
      return
    }
    try ClaudeCredentialsWriter(capturedAccounts: capturedAccounts).persist(
      pending.grant,
      replacing: stored.accessToken,
      to: .quotariRegistry(id: id)
    )
    _ = try capturedAccounts.removePendingGrant(id: id, matching: data)
  }

  enum LinkedMirrorResult: Equatable {
    case ready
    case unrelated
    case blocked
  }

  func mirrorAcceptedGrant(_ pending: ClaudePendingGrant, to id: String) -> LinkedMirrorResult {
    guard claimLinkedGrant(pending, id: id) else { return .blocked }
    do {
      try ClaudeCredentialsWriter(capturedAccounts: capturedAccounts).persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        to: .quotariRegistry(id: id)
      )
      removeLinkedGrantIfMatching(pending, id: id)
      return .ready
    } catch ClaudeCredentialPersistError.staleSource {
      return resolveStaleLinkedMirror(pending, id: id)
    } catch {
      return .blocked
    }
  }

  private func resolveStaleLinkedMirror(
    _ pending: ClaudePendingGrant,
    id: String
  ) -> LinkedMirrorResult {
    guard let stored = try? ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: id),
      capturedAccounts: capturedAccounts
    ) else {
      return .blocked
    }
    if pending.matchesInstalledGeneration(
      accessToken: stored.accessToken,
      refreshToken: stored.refreshToken
    ) {
      removeLinkedGrantIfMatching(pending, id: id)
      return .ready
    }
    if pending.supersedes(
      accessToken: stored.accessToken,
      refreshToken: stored.refreshToken
    ) {
      return .blocked
    }
    removeLinkedGrantIfMatching(pending, id: id)
    return .unrelated
  }

  private func claimLinkedGrant(_ pending: ClaudePendingGrant, id: String) -> Bool {
    guard let data = try? JSONEncoder().encode(pending) else { return false }
    do {
      if try !capturedAccounts.savePendingGrantIfAbsent(data, id: id) {
        Self.logger.notice("A different pending grant already owns the linked saved account.")
        return false
      }
      return true
    } catch {
      Self.logger.error("Saving a linked pending grant failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func removeLinkedGrantIfMatching(_ pending: ClaudePendingGrant, id: String) {
    _ = try? capturedAccounts.removePendingGrant(id: id) { data in
      (try? JSONDecoder().decode(ClaudePendingGrant.self, from: data)) == pending
    }
  }

  /// Memory first (cheap), then the durable copy a previous launch left.
  /// The durable copy is deliberately NOT consumed here: it holds the only
  /// rotated pair, so it stays until the source write succeeds or is proven
  /// obsolete; a crash mid-retry must not lose it.
  func loadDurablePending(source: ProviderCredentialSource) throws -> ClaudePendingGrant? {
    guard let slot = durablePendingSlot(source: source),
          let data = try capturedAccounts.loadPendingGrantData(id: slot.id)
    else { return nil }
    do {
      return try JSONDecoder().decode(ClaudePendingGrant.self, from: data)
    } catch {
      throw ClaudeCredentialPersistError.malformedPayload
    }
  }

  func takePending(
    source: ProviderCredentialSource,
    durablePending: ClaudePendingGrant?
  ) async -> ClaudePendingGrant? {
    if let pending = await refreshCoordinator.takeUnpersisted(sourceID: source.stableID) {
      return pending
    }
    return durablePending
  }

  /// Queues in memory and, best-effort, durably — so quitting before the
  /// next fetch doesn't lose the only rotated pair.
  func rememberPending(_ pending: ClaudePendingGrant, source: ProviderCredentialSource) async {
    guard let slot = durablePendingSlot(source: source),
          let data = try? JSONEncoder().encode(pending)
    else { return }
    if case .liveSource = slot, !pending.rotatedRefreshToken {
      // The stored refresh token remains usable, so retaining an access-only
      // grant could later overwrite a fresher CLI-owned generation.
      return
    }
    do {
      let claimed = switch slot {
      case let .capturedAccount(id):
        try capturedAccounts.savePendingGrantIfAbsent(data, id: id)
      case let .liveSource(id):
        try capturedAccounts.saveLivePendingGrantIfAbsent(data, id: id)
      }
      guard claimed else {
        Self.logger.notice("A different pending grant already owns the credential source.")
        return
      }
    } catch {
      Self.logger.error("Saving a pending Claude grant failed: \(error.localizedDescription, privacy: .public)")
    }
    await refreshCoordinator.rememberUnpersisted(pending, sourceID: source.stableID)
  }

  func removeDurableGrantIfMatching(
    _ pending: ClaudePendingGrant,
    source: ProviderCredentialSource
  ) {
    guard let slot = durablePendingSlot(source: source) else { return }
    _ = try? capturedAccounts.removePendingGrant(id: slot.id) { data in
      (try? JSONDecoder().decode(ClaudePendingGrant.self, from: data)) == pending
    }
  }

  private func durablePendingSlot(source: ProviderCredentialSource) -> DurablePendingSlot? {
    switch source {
    case let .quotariRegistry(id):
      .capturedAccount(id)
    case .claudeKeychain, .claudeCredentialsFile:
      source.claudeLivePendingGrantID.map(DurablePendingSlot.liveSource)
    case .codexAuthFile, .codexKeychain, .claudeEnvironment:
      nil
    }
  }

  /// The credentials patched with a grant that isn't (or isn't yet) stored —
  /// good for fetching with while the source catches up.
  func inMemory(
    _ resolved: ResolvedClaudeCredentials,
    _ grant: ClaudeTokenGrant
  ) -> ResolvedClaudeCredentials {
    var credentials = resolved.credentials
    credentials.accessToken = grant.accessToken
    credentials.refreshToken = grant.refreshToken ?? credentials.refreshToken
    credentials.expiresAt = grant.expiresAt
    credentials.scopes = grant.scopes ?? credentials.scopes
    return ResolvedClaudeCredentials(credentials: credentials, source: resolved.source)
  }

  func reloadedFromSource(
    _ resolved: ResolvedClaudeCredentials,
    now: Date
  ) -> ResolvedClaudeCredentials? {
    guard let reloaded = try? ClaudeCredentialsStore.load(
      source: resolved.source,
      capturedAccounts: capturedAccounts
    ), !reloaded.isExpired(now: now)
    else { return nil }
    return ResolvedClaudeCredentials(credentials: reloaded, source: resolved.source)
  }
}
