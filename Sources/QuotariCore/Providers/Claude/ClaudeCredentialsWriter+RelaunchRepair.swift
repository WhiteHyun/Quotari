import Foundation

extension ClaudeCredentialsWriter {
  private enum CanonicalMirrorCommitResult {
    case resolved
    case pending
    case staleCanonical
  }

  /// A previous launch may have installed the rotated keychain pair and then
  /// failed to update Claude's matching credentials file. The canonical
  /// journal proves which exact generation owns that repair; unrelated
  /// keychain generations are never treated as permission to touch the file.
  func repairInstalledMirrorIfNeeded(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    canonicalPayload: Data,
    keychainService: String
  ) throws -> Bool {
    guard let canonical = try matchingCanonicalRecovery(
      grant,
      replacing: previousAccessToken,
      keychainService: keychainService
    ), let current = try? ClaudeCredentialsStore.parse(canonicalPayload)
    else { return false }

    guard current.accessToken == canonical.pending.grant.accessToken,
          current.refreshToken == canonical.pending.grant.refreshToken
    else {
      if !canonical.pending.supersedes(
        accessToken: current.accessToken,
        refreshToken: current.refreshToken
      ) {
        removeObsoleteRecovery(canonical, keychainService: keychainService)
      }
      return false
    }

    let recovery = try mirrorRecovery(
      canonical.pending.grant,
      replacing: canonical.pending.previousAccessToken,
      pending: canonical.pending,
      keychainService: keychainService
    )
    defer { secureFileWriter.discard(recovery.preparation.temporary) }
    if let journal = recovery.journal {
      try installRecoveryJournal(journal)
    }
    switch commitMirrorWhileCanonicalUnchanged(
      recovery.preparation,
      pending: recovery.journal?.pending ?? canonical.pending,
      keychainService: keychainService
    ) {
    case .resolved:
      break
    case .pending:
      throw ClaudeCredentialPersistError.mirrorRecoveryPending(
        underlying: "The canonical keychain grant is installed, but its credentials file mirror is still pending."
      )
    case .staleCanonical:
      throw ClaudeCredentialPersistError.staleSource
    }
    guard removeResolvedMirrorJournals(recovery), removeRecoveryJournal(canonical) else {
      throw ClaudeCredentialPersistError.mirrorRecoveryPending(
        underlying: "The mirror is repaired, but its recovery journal cleanup is still pending."
      )
    }
    return true
  }

  private func commitMirrorWhileCanonicalUnchanged(
    _ preparation: MirrorPreparation,
    pending: ClaudePendingGrant,
    keychainService: String
  ) -> CanonicalMirrorCommitResult {
    guard canonicalSourceOwns(pending, keychainService: keychainService) else {
      Self.logger.notice("Claude's canonical keychain changed before mirror repair; leaving recovery queued.")
      return .staleCanonical
    }
    let resolved = commitMirrorIfUnchanged(preparation, pending: pending)
    guard canonicalSourceOwns(pending, keychainService: keychainService) else {
      Self.logger.notice("Claude's canonical keychain changed during mirror repair; leaving recovery queued.")
      return .staleCanonical
    }
    return resolved ? .resolved : .pending
  }

  private func canonicalSourceOwns(
    _ pending: ClaudePendingGrant,
    keychainService: String
  ) -> Bool {
    guard let payload = keychainRead(keychainService),
          let credentials = try? ClaudeCredentialsStore.parse(payload)
    else { return false }
    return credentials.accessToken == pending.grant.accessToken
      && credentials.refreshToken == pending.grant.refreshToken
  }

  func removeResolvedMirrorJournals(_ recovery: MirrorRecovery) -> Bool {
    var resolved = true
    if let journal = recovery.journal {
      resolved = removeRecoveryJournal(journal) && resolved
    }
    if let cleanup = recovery.cleanup {
      resolved = removeRecoveryJournal(cleanup) && resolved
    }
    return resolved
  }

  func mirrorJournalIsResolved(
    _ pending: ClaudePendingGrant,
    destination: URL
  ) -> Bool {
    do {
      return try !mirrorNeedsRecovery(fileRead(destination), pending: pending)
    } catch {
      return mirrorDestinationIsMissing(error)
    }
  }

  func mirrorDestinationIsMissing(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain {
      return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
    }
    return error.domain == NSPOSIXErrorDomain
      && error.code == Int(POSIXErrorCode.ENOENT.rawValue)
  }

  func mirrorNeedsRecovery(
    _ payload: Data,
    pending: ClaudePendingGrant?
  ) -> Bool {
    guard let pending else { return false }
    guard let credentials = try? ClaudeCredentialsStore.parse(payload) else { return true }
    if credentials.accessToken == pending.grant.accessToken {
      return pending.grant.refreshToken.map { credentials.refreshToken != $0 } ?? false
    }
    return pending.supersedes(
      accessToken: credentials.accessToken,
      refreshToken: credentials.refreshToken
    )
  }

  @discardableResult
  func removeRecoveryJournal(_ journal: MirrorRecoveryJournal) -> Bool {
    do {
      let removed = try capturedAccounts.removePendingGrant(id: journal.id) { data in
        try JSONDecoder().decode(ClaudePendingGrant.self, from: data) == journal.pending
      }
      if removed {
        return true
      }
      return try loadRecoveryJournal(id: journal.id) != journal.pending
    } catch {
      Self.logger.error(
        "Cleaning up Claude's mirrored recovery journal failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  private func matchingCanonicalRecovery(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    keychainService: String
  ) throws -> MirrorRecoveryJournal? {
    guard let id = ProviderCredentialSource
      .claudeKeychain(service: keychainService)
      .claudeLivePendingGrantID,
      let pending = try loadRecoveryJournal(id: id),
      pending.grant == grant,
      pending.previousAccessToken == previousAccessToken
    else { return nil }
    return MirrorRecoveryJournal(id: id, pending: pending, previous: pending)
  }

  private func removeObsoleteRecovery(
    _ canonical: MirrorRecoveryJournal,
    keychainService: String
  ) {
    guard keychainService == ClaudeCredentialsStore.keychainService,
          let destination = mirroredCredentialsFileURL,
          let id = ProviderCredentialSource
          .claudeCredentialsFile(path: destination.standardizedFileURL.path)
          .claudeLivePendingGrantID
    else {
      removeRecoveryJournal(canonical)
      return
    }
    do {
      guard let pending = try loadRecoveryJournal(id: id),
            canonical.pending.mergingLineage(with: pending) != nil
      else {
        removeRecoveryJournal(canonical)
        return
      }
      let mirror = MirrorRecoveryJournal(id: id, pending: pending, previous: pending)
      if removeRecoveryJournal(mirror) {
        removeRecoveryJournal(canonical)
      }
    } catch {
      Self.logger.error(
        "Inspecting Claude's obsolete mirror recovery failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
