import Foundation
import os

private let accountSwitchPendingGrantLogger = Logger(
  subsystem: "com.quotari.QuotariCore",
  category: "account-switch"
)

extension AccountSwitchService {
  struct ClaudeBackupContext {
    var registryID: String
    var now: Date
    var knownLiveTarget: KnownLiveClaudeTarget?
  }

  struct ClaudeLiveSnapshot {
    var pendingGrants: [ClaudeLivePendingGrant]
    var slots: ResolvedClaudeLivePayloads
    var resolvedSlots: ResolvedClaudeLivePayloads
  }

  struct ClaudeLivePendingGrant: Equatable {
    var id: String
    var pending: ClaudePendingGrant
  }

  struct ResolvedClaudeLivePayloads {
    var keychain: Data?
    var file: Data?
  }

  /// Re-reads the target's saved payload from the registry: a backup earlier
  /// in the switch can refresh the same registry id, so the transplant must
  /// use the freshest stored payload rather than its pre-backup value.
  func targetPayload(registryID: String) throws -> Data {
    guard let saved = capturedAccounts.account(id: registryID) else {
      throw AccountSwitchError.accountNotFound
    }
    guard let pendingData = try pendingGrantData(registryID: registryID) else {
      return saved.payload
    }
    do {
      let applied = try applyPendingGrant(
        pendingData,
        saved: saved,
        registryID: registryID
      )
      _ = try? capturedAccounts.removePendingGrant(id: registryID, matching: pendingData)
      guard applied else { return saved.payload }
      guard let updated = capturedAccounts.account(id: registryID) else {
        throw AccountSwitchError.accountNotFound
      }
      return updated.payload
    } catch {
      throw AccountSwitchError.writeFailed(
        underlying: "Couldn't apply the saved account's pending token grant: \(error.localizedDescription)"
      )
    }
  }

  private func pendingGrantData(registryID: String) throws -> Data? {
    do {
      return try capturedAccounts.loadPendingGrantData(id: registryID)
    } catch {
      throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
    }
  }

  private func applyPendingGrant(
    _ data: Data,
    saved: CapturedAccount,
    registryID: String
  ) throws -> Bool {
    switch saved.provider {
    case .claude:
      try applyClaudePendingGrant(data, saved: saved, registryID: registryID)
    case .codex:
      try applyCodexPendingGrant(data, saved: saved, registryID: registryID)
    }
  }

  private func applyClaudePendingGrant(
    _ data: Data,
    saved: CapturedAccount,
    registryID: String
  ) throws -> Bool {
    guard let pending = try? JSONDecoder().decode(ClaudePendingGrant.self, from: data),
          let credentials = try? ClaudeCredentialsStore.parse(saved.payload)
    else { throw ClaudeCredentialPersistError.malformedPayload }
    guard pending.supersedes(
      accessToken: credentials.accessToken,
      refreshToken: credentials.refreshToken
    )
    else { return false }
    try ClaudeCredentialsWriter(capturedAccounts: capturedAccounts).persist(
      pending.grant,
      replacing: credentials.accessToken,
      to: .quotariRegistry(id: registryID)
    )
    return true
  }

  private func applyCodexPendingGrant(
    _ data: Data,
    saved: CapturedAccount,
    registryID: String
  ) throws -> Bool {
    guard let pending = try? JSONDecoder().decode(CodexPendingGrant.self, from: data),
          let credentials = try? CodexCredentialsStore.parse(saved.payload)
    else { throw CodexCredentialPersistError.malformedPayload }
    guard credentials.accessToken == pending.previousAccessToken
      || (credentials.refreshToken == pending.consumedRefreshToken && pending.rotatedRefreshToken)
    else { return false }
    try CodexCredentialsWriter(capturedAccounts: capturedAccounts).persist(
      pending.grant,
      replacing: credentials.accessToken,
      toRegistryAccount: registryID
    )
    return true
  }

  /// Reads every recovery item before the switch captures or overwrites a
  /// Claude slot. A keychain failure or malformed item must fail closed: the
  /// pending grant may hold the only refresh token that still works.
  func loadClaudeLivePendingGrants(
    sources: [ProviderCredentialSource]
  ) throws -> [ClaudeLivePendingGrant] {
    try sources.compactMap { source in
      guard let id = source.claudeLivePendingGrantID else { return nil }
      let data: Data?
      do {
        data = try capturedAccounts.loadPendingGrantData(id: id)
      } catch {
        throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
      }
      guard let data else { return nil }
      guard let pending = try? JSONDecoder().decode(ClaudePendingGrant.self, from: data) else {
        throw AccountSwitchError.slotReadFailed(
          underlying: ClaudeCredentialPersistError.malformedPayload.localizedDescription
        )
      }
      return ClaudeLivePendingGrant(id: id, pending: pending)
    }
    .sorted { $0.id < $1.id }
  }

  /// Replays each durable grant only onto payloads from its exact token
  /// generation. Matching keychain/file mirrors both inherit the recovered
  /// pair, while an unrelated login is left untouched. Every unbacked pending
  /// item must be represented by at least one slot before the switch proceeds;
  /// a marked item can be unmatched only because an earlier committed switch
  /// left cleanup debt after durably saving the resolved generation.
  func resolveClaudeLivePendingGrants(
    _ pendingGrants: [ClaudeLivePendingGrant],
    keychain: Data?,
    file: Data?
  ) throws -> ResolvedClaudeLivePayloads {
    guard !pendingGrants.isEmpty else {
      return ResolvedClaudeLivePayloads(keychain: keychain, file: file)
    }
    var resolvedPendingIndices = Set<Int>()
    let resolvedKeychain = try resolveClaudeLivePendingGrants(
      pendingGrants,
      in: keychain,
      resolvedPendingIndices: &resolvedPendingIndices
    )
    let resolvedFile = try resolveClaudeLivePendingGrants(
      pendingGrants,
      in: file,
      resolvedPendingIndices: &resolvedPendingIndices
    )
    let unresolved = pendingGrants.indices.filter { !resolvedPendingIndices.contains($0) }
    guard unresolved.allSatisfy({ pendingGrants[$0].pending.liveSourceBackupRecorded == true }) else {
      throw AccountSwitchError.backupFailed(
        underlying: "A pending Claude token grant no longer matches either live credential slot."
      )
    }
    return ResolvedClaudeLivePayloads(
      keychain: resolvedKeychain,
      file: resolvedFile
    )
  }

  /// Clears only the exact recovery items that produced the durable backups.
  /// A different concurrent owner survives; the switch aborts and can retry
  /// from a fresh snapshot rather than guessing which grant now wins.
  func removeClaudeLivePendingGrants(
    _ pendingGrants: [ClaudeLivePendingGrant]
  ) throws {
    for record in pendingGrants {
      let removed: Bool
      do {
        removed = try capturedAccounts.removePendingGrant(id: record.id) { data in
          (try? JSONDecoder().decode(ClaudePendingGrant.self, from: data)) == record.pending
        }
      } catch {
        throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
      }
      guard removed else {
        throw AccountSwitchError.slotReadFailed(
          underlying: "A pending Claude token grant changed during the account switch."
        )
      }
    }
  }

  /// The live stores have already committed. Cleanup must not turn that
  /// successful switch into a reported failure: an exact stale recovery is
  /// generation-gated and a newer concurrent owner must remain untouched.
  func discardClaudeLivePendingGrantsAfterSuccessfulSwitch(
    _ pendingGrants: [ClaudeLivePendingGrant]
  ) {
    do {
      try removeClaudeLivePendingGrants(pendingGrants)
    } catch {
      accountSwitchPendingGrantLogger
        .error("Cleaning up a resolved Claude recovery grant failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Advances each exact recovery only after its resolved payload has been
  /// saved in the registry. If post-commit deletion later fails, a future
  /// switch can distinguish cleanup debt from an unbacked live generation.
  func recordDurableClaudeLivePendingGrantBackups(
    _ pendingGrants: [ClaudeLivePendingGrant]
  ) throws -> [ClaudeLivePendingGrant] {
    try pendingGrants.map { record in
      guard record.pending.liveSourceBackupRecorded != true else { return record }
      var marked = record.pending
      marked.liveSourceBackupRecorded = true
      let replacement = try JSONEncoder().encode(marked)
      let replaced: Bool
      do {
        replaced = try capturedAccounts.replacePendingGrant(
          id: record.id,
          when: { data in
            try JSONDecoder().decode(ClaudePendingGrant.self, from: data) == record.pending
          },
          with: replacement
        )
      } catch {
        throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
      }
      guard replaced else {
        throw AccountSwitchError.slotReadFailed(
          underlying: "A pending Claude token grant changed during the account switch."
        )
      }
      return ClaudeLivePendingGrant(id: record.id, pending: marked)
    }
  }
}

private extension AccountSwitchService {
  func resolveClaudeLivePendingGrants(
    _ pendingGrants: [ClaudeLivePendingGrant],
    in payload: Data?,
    resolvedPendingIndices: inout Set<Int>
  ) throws -> Data? {
    guard var payload else { return nil }
    var handledInThisSlot = Set<Int>()
    let writer = ClaudeCredentialsWriter(capturedAccounts: capturedAccounts)

    while let credentials = try? ClaudeCredentialsStore.parse(payload) {
      let alreadyApplied = pendingGrants.indices.filter { index in
        !handledInThisSlot.contains(index)
          && credentials.accessToken == pendingGrants[index].pending.grant.accessToken
      }
      if !alreadyApplied.isEmpty {
        let grant = pendingGrants[alreadyApplied[0]].pending.grant
        guard alreadyApplied.allSatisfy({ pendingGrants[$0].pending.grant == grant }) else {
          throw AccountSwitchError.backupFailed(
            underlying: "Conflicting pending Claude token grants match the same live credential generation."
          )
        }
        payload = try writer.merge(
          grant,
          replacing: credentials.accessToken,
          into: payload
        )
        handledInThisSlot.formUnion(alreadyApplied)
        resolvedPendingIndices.formUnion(alreadyApplied)
        continue
      }

      let applicable = pendingGrants.indices.filter { index in
        guard !handledInThisSlot.contains(index) else { return false }
        let pending = pendingGrants[index].pending
        return pending.supersedes(
          accessToken: credentials.accessToken,
          refreshToken: credentials.refreshToken
        )
      }
      guard !applicable.isEmpty else { break }
      let grant = pendingGrants[applicable[0]].pending.grant
      guard applicable.allSatisfy({ pendingGrants[$0].pending.grant == grant }) else {
        throw AccountSwitchError.backupFailed(
          underlying: "Conflicting pending Claude token grants match the same live credential generation."
        )
      }
      payload = try writer.merge(
        grant,
        replacing: credentials.accessToken,
        into: payload
      )
      handledInThisSlot.formUnion(applicable)
      resolvedPendingIndices.formUnion(applicable)
    }
    return payload
  }
}
