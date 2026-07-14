import Foundation
import os

extension ClaudeCredentialsWriter {
  enum MirrorPreparation {
    case none
    case failed(destination: URL)
    case prepared(PreparedMirror)

    var temporary: URL? {
      guard case let .prepared(mirror) = self else { return nil }
      return mirror.temporary
    }

    var requiresJournal: Bool {
      switch self {
      case .none: false
      case .failed, .prepared: true
      }
    }
  }

  struct PreparedMirror {
    var destination: URL
    var original: Data
    var temporary: URL
  }

  struct MirrorRecovery {
    var preparation: MirrorPreparation
    var journal: MirrorRecoveryJournal?
    var cleanup: MirrorRecoveryJournal?
  }

  struct MirrorRecoveryJournal {
    var id: String
    var pending: ClaudePendingGrant
    var previous: ClaudePendingGrant?
  }

  /// The stable inputs of a mirror reconciliation, bundled so the per-branch
  /// helpers stay within the parameter budget.
  private struct MirrorRecoveryContext {
    var grant: ClaudeTokenGrant
    var previousAccessToken: String
    var pending: ClaudePendingGrant
    var keychainService: String
  }

  func mirrorRecovery(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    pending: ClaudePendingGrant?,
    keychainService: String
  ) throws -> MirrorRecovery {
    let initial = preparedMirror(
      grant,
      replacing: previousAccessToken,
      pending: pending,
      keychainService: keychainService
    )
    guard let pending,
          keychainService == ClaudeCredentialsStore.keychainService,
          let destination = mirroredCredentialsFileURL,
          let id = ProviderCredentialSource
          .claudeCredentialsFile(path: destination.standardizedFileURL.path)
          .claudeLivePendingGrantID
    else { return MirrorRecovery(preparation: initial, journal: nil, cleanup: nil) }

    let context = MirrorRecoveryContext(
      grant: grant,
      previousAccessToken: previousAccessToken,
      pending: pending,
      keychainService: keychainService
    )
    switch initial {
    case .none:
      return try mirrorRecoveryReconcilingMissingPreparation(initial, context: context, id: id)
    case .failed, .prepared:
      return try mirrorRecoveryReconcilingPreparedMirror(initial, context: context, id: id)
    }
  }

  private func mirrorRecoveryReconcilingMissingPreparation(
    _ initial: MirrorPreparation,
    context: MirrorRecoveryContext,
    id: String
  ) throws -> MirrorRecovery {
    // The file may be one rotation behind the canonical keychain. Only an
    // exact existing journal can bridge that lineage; an unrelated file is
    // intentionally left alone.
    guard let existing = try loadRecoveryJournal(id: id) else {
      return MirrorRecovery(preparation: initial, journal: nil, cleanup: nil)
    }
    let effective: ClaudePendingGrant
    if let merged = context.pending.mergingLineage(with: existing) {
      effective = merged
    } else if let chained = context.pending.chaining(after: existing) {
      // Chaining takes precedence even when the predecessor was marked as
      // backed up: it may still be the only bridge to a stale file.
      effective = chained
    } else {
      return MirrorRecovery(preparation: initial, journal: nil, cleanup: nil)
    }
    let preparation = reprepareMirror(
      discarding: initial,
      context.grant,
      replacing: context.previousAccessToken,
      pending: effective,
      keychainService: context.keychainService
    )
    guard preparation.requiresJournal else {
      return MirrorRecovery(
        preparation: preparation,
        journal: nil,
        cleanup: MirrorRecoveryJournal(id: id, pending: existing, previous: existing)
      )
    }
    return MirrorRecovery(
      preparation: preparation,
      journal: MirrorRecoveryJournal(id: id, pending: effective, previous: existing),
      cleanup: nil
    )
  }

  private func mirrorRecoveryReconcilingPreparedMirror(
    _ initial: MirrorPreparation,
    context: MirrorRecoveryContext,
    id: String
  ) throws -> MirrorRecovery {
    let existing = try loadRecoveryJournal(id: id)
    let effective = try effectiveMirrorGrant(
      pending: context.pending,
      existing: existing,
      conflictSource: "mirrored"
    )
    let preparation = effective == context.pending ? initial : reprepareMirror(
      discarding: initial,
      context.grant,
      replacing: context.previousAccessToken,
      pending: effective,
      keychainService: context.keychainService
    )
    guard preparation.requiresJournal else {
      return MirrorRecovery(preparation: preparation, journal: nil, cleanup: nil)
    }
    return MirrorRecovery(
      preparation: preparation,
      journal: MirrorRecoveryJournal(id: id, pending: effective, previous: existing),
      cleanup: nil
    )
  }

  /// Reconciles a fresh grant against an existing journal, returning the grant
  /// that should own the source. Throws when a different, unbacked grant
  /// already owns it and no lineage bridges the two.
  private func effectiveMirrorGrant(
    pending: ClaudePendingGrant,
    existing: ClaudePendingGrant?,
    conflictSource: String
  ) throws -> ClaudePendingGrant {
    guard let existing else { return pending }
    if existing == pending {
      return pending
    } else if let merged = pending.mergingLineage(with: existing) {
      return merged
    } else if let chained = pending.chaining(after: existing) {
      return chained
    } else if existing.liveSourceBackupRecorded == true {
      // A marked record that cannot bridge the current generation is only
      // cleanup debt whose resolved generation was backed up durably.
      return pending
    }
    throw ClaudeCredentialPersistError.recoveryJournalFailed(
      underlying: "A different unbacked grant already owns the \(conflictSource) credential source."
    )
  }

  private func reprepareMirror(
    discarding initial: MirrorPreparation,
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    pending: ClaudePendingGrant,
    keychainService: String
  ) -> MirrorPreparation {
    secureFileWriter.discard(initial.temporary)
    return preparedMirror(
      grant,
      replacing: previousAccessToken,
      pending: pending,
      keychainService: keychainService
    )
  }

  /// The switch mirrors only the canonical Claude keychain and default file.
  /// Never create the file, touch a custom service, or overwrite a file that
  /// belongs to another login/generation.
  private func preparedMirror(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    pending: ClaudePendingGrant?,
    keychainService: String
  ) -> MirrorPreparation {
    guard keychainService == ClaudeCredentialsStore.keychainService,
          let destination = mirroredCredentialsFileURL,
          FileManager.default.fileExists(atPath: destination.path)
    else { return .none }
    let original: Data
    do {
      original = try fileRead(destination)
    } catch {
      Self.logger
        .error("Reading the mirrored Claude credentials file failed: \(error.localizedDescription, privacy: .public)")
      return .failed(destination: destination)
    }
    guard let accessToken = mirrorAccessToken(
      in: original,
      previousAccessToken: previousAccessToken,
      pending: pending
    ),
      let merged = try? merge(grant, replacing: accessToken, into: original)
    else {
      return .none
    }
    do {
      return try .prepared(PreparedMirror(
        destination: destination,
        original: original,
        temporary: secureFileWriter.prepare(merged, replacing: destination)
      ))
    } catch {
      Self.logger
        .error("Preparing the mirrored Claude credentials file failed: \(error.localizedDescription, privacy: .public)")
      return .failed(destination: destination)
    }
  }

  /// The recovery journal is installed before the canonical keychain write.
  /// A mirror failure must never roll the keychain back to a consumed token;
  /// leave the journal for a later refresh or account switch instead.
  func commitMirrorIfUnchanged(
    _ preparation: MirrorPreparation,
    pending: ClaudePendingGrant?
  ) -> Bool {
    switch preparation {
    case .none:
      return true
    case let .failed(destination):
      Self.logger
        .notice("Claude's credentials file mirror remains queued for repair at \(destination.path, privacy: .private).")
      return false
    case let .prepared(mirror):
      return commitPreparedMirrorIfUnchanged(mirror, pending: pending)
    }
  }

  private func commitPreparedMirrorIfUnchanged(
    _ mirror: PreparedMirror,
    pending: ClaudePendingGrant?
  ) -> Bool {
    do {
      let current = try fileRead(mirror.destination)
      guard current == mirror.original else {
        Self.logger.notice("Claude's credentials file changed during refresh; leaving it untouched.")
        return !mirrorNeedsRecovery(current, pending: pending)
      }
      try commitMirroredFile(mirror.temporary, mirror.destination)
      return true
    } catch {
      Self.logger
        .error("Mirroring refreshed Claude credentials failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  private func mirrorAccessToken(
    in payload: Data,
    previousAccessToken: String,
    pending: ClaudePendingGrant?
  ) -> String? {
    guard let credentials = try? ClaudeCredentialsStore.parse(payload) else { return nil }
    if credentials.accessToken == previousAccessToken {
      return credentials.accessToken
    }
    guard let pending,
          pending.supersedes(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken
          )
    else { return nil }
    return credentials.accessToken
  }

  private func mirrorNeedsRecovery(
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

  func mirrorPendingGrant(
    _ grant: ClaudeTokenGrant,
    previousAccessToken: String,
    canonicalPayload: Data
  ) -> ClaudePendingGrant? {
    guard let credentials = try? ClaudeCredentialsStore.parse(canonicalPayload),
          let consumedRefreshToken = credentials.refreshToken
    else { return nil }
    let pending = ClaudePendingGrant(
      grant: grant,
      previousAccessToken: previousAccessToken,
      consumedRefreshToken: consumedRefreshToken
    )
    return pending.rotatedRefreshToken ? pending : nil
  }

  func loadRecoveryJournal(id: String) throws -> ClaudePendingGrant? {
    do {
      guard let data = try capturedAccounts.loadPendingGrantData(id: id) else { return nil }
      guard let pending = try? JSONDecoder().decode(ClaudePendingGrant.self, from: data) else {
        throw ClaudeCredentialPersistError.malformedPayload
      }
      return pending
    } catch {
      throw ClaudeCredentialPersistError.recoveryJournalFailed(
        underlying: error.localizedDescription
      )
    }
  }

  /// Retained until the next fetch proves every matching mirror is resolved.
  func canonicalRecoveryJournal(
    pending: ClaudePendingGrant?,
    keychainService: String
  ) throws -> MirrorRecoveryJournal? {
    guard let pending,
          let id = ProviderCredentialSource
          .claudeKeychain(service: keychainService)
          .claudeLivePendingGrantID
    else { return nil }
    let existing = try loadRecoveryJournal(id: id)
    let effective = try effectiveMirrorGrant(
      pending: pending,
      existing: existing,
      conflictSource: "canonical"
    )
    return MirrorRecoveryJournal(id: id, pending: effective, previous: existing)
  }

  /// Installs or advances an exact source journal before publishing the
  /// canonical keychain generation. A concurrent unbacked owner wins.
  func installRecoveryJournal(_ journal: MirrorRecoveryJournal) throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(journal.pending)
      let installed: Bool = if let previous = journal.previous {
        try capturedAccounts.replacePendingGrant(
          id: journal.id,
          when: { current in
            try JSONDecoder().decode(ClaudePendingGrant.self, from: current) == previous
          },
          with: data
        )
      } else {
        try capturedAccounts.saveLivePendingGrantIfAbsent(data, id: journal.id)
      }
      guard installed else {
        throw ClaudeCredentialPersistError.recoveryJournalFailed(
          underlying: "The mirrored credential recovery changed concurrently."
        )
      }
    } catch let error as ClaudeCredentialPersistError {
      throw error
    } catch {
      throw ClaudeCredentialPersistError.recoveryJournalFailed(
        underlying: error.localizedDescription
      )
    }
  }
}
