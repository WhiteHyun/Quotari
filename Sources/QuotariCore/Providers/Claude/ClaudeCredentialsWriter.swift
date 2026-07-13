import Foundation
import os

public protocol ClaudeCredentialPersisting: Sendable {
  /// Persists a refreshed token pair, but only if the source still holds
  /// `previousAccessToken` — a different token means someone re-logged-in or
  /// rotated behind our back, and overwriting would clobber the newer pair.
  func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws
}

public enum ClaudeCredentialPersistError: LocalizedError, Sendable {
  case sourceUnavailable
  case malformedPayload
  case staleSource
  case keychainWriteFailed(status: Int32)
  case recoveryJournalFailed(underlying: String)

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable: "The credential source can't be written to."
    case .malformedPayload: "The stored credentials payload is malformed."
    case .staleSource: "The credential source changed since the refresh started."
    case let .keychainWriteFailed(status): "Writing the keychain item failed (security exited \(status))."
    case let .recoveryJournalFailed(underlying):
      "Saving Claude's mirror recovery journal failed: \(underlying)"
    }
  }
}

/// Writes a refreshed token pair back to the source Claude Code reads from,
/// so both apps keep using the same (possibly rotated) refresh token. Only the
/// token fields inside `claudeAiOauth` change — everything else in the payload
/// (`mcpOAuth`, plan metadata, unknown future keys) is semantically preserved.
public struct ClaudeCredentialsWriter: ClaudeCredentialPersisting {
  private static let logger = Logger(subsystem: "com.quotari.QuotariCore", category: "claude-credentials")

  private let keychainRead: @Sendable (String) -> Data?
  private let keychainWrite: @Sendable (Data, String) throws -> Void
  private let capturedAccounts: CapturedAccountStore
  private let mirroredCredentialsFileURL: URL?
  private let fileRead: @Sendable (URL) throws -> Data
  private let secureFileWriter: SecureCredentialFileWriter
  private let commitMirroredFile: @Sendable (URL, URL) throws -> Void

  public init(
    keychainRead: (@Sendable (String) -> Data?)? = nil,
    keychainWrite: (@Sendable (Data, String) throws -> Void)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    mirroredCredentialsFileURL: URL? = nil,
    fileRead: (@Sendable (URL) throws -> Data)? = nil,
    setOwnerOnlyPermissions: (@Sendable (URL) throws -> Void)? = nil,
    commitMirroredFile: (@Sendable (URL, URL) throws -> Void)? = nil
  ) {
    self.keychainRead = keychainRead ?? { ClaudeCredentialsStore.keychainItem(service: $0) }
    self.keychainWrite = keychainWrite ?? { try KeychainItemStore.writeByService($0, service: $1) }
    self.capturedAccounts = capturedAccounts
    self.mirroredCredentialsFileURL = mirroredCredentialsFileURL
    self.fileRead = fileRead ?? { try Data(contentsOf: $0) }
    let secureFileWriter = SecureCredentialFileWriter(
      setOwnerOnlyPermissions: setOwnerOnlyPermissions ?? { url in
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    )
    self.secureFileWriter = secureFileWriter
    self.commitMirroredFile = commitMirroredFile ?? { temporary, destination in
      try secureFileWriter.commit(temporary, replacing: destination)
    }
  }

  public func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws {
    switch source {
    case .claudeEnvironment:
      return // env tokens are static; nothing to write back
    case let .claudeCredentialsFile(path):
      let url = URL(fileURLWithPath: path)
      let merged = try merge(grant, replacing: previousAccessToken, into: Data(contentsOf: url))
      let prepared = try secureFileWriter.prepare(merged, replacing: url)
      defer { secureFileWriter.discard(prepared) }
      try secureFileWriter.commit(prepared, replacing: url)
    case let .claudeKeychain(service):
      guard let data = keychainRead(service) else { throw ClaudeCredentialPersistError.sourceUnavailable }
      let mergedKeychain = try merge(grant, replacing: previousAccessToken, into: data)
      let pending = mirrorPendingGrant(
        grant,
        previousAccessToken: previousAccessToken,
        canonicalPayload: data
      )
      let canonicalJournal = try canonicalRecoveryJournal(
        pending: pending,
        keychainService: service
      )
      if let canonicalJournal {
        // Protect the consumed canonical generation before any mirror I/O.
        // A crash during file reads or temporary-file preparation must not
        // lose the only grant that can replace the now-dead refresh token.
        try installRecoveryJournal(canonicalJournal)
      }
      let recovery = try mirrorRecovery(
        grant,
        replacing: previousAccessToken,
        pending: pending,
        keychainService: service
      )
      defer { secureFileWriter.discard(recovery.preparation.temporary) }
      if let journal = recovery.journal {
        try installRecoveryJournal(journal)
      }
      try keychainWrite(mergedKeychain, service)
      if let canonicalJournal {
        // The canonical source now owns the grant. Its short-lived journal is
        // no longer needed; the file journal remains until the mirror lands.
        removeRecoveryJournal(canonicalJournal)
      }
      let mirrorResolved = commitMirrorIfUnchanged(
        recovery.preparation,
        pending: recovery.journal?.pending ?? pending
      )
      if mirrorResolved, let journal = recovery.journal {
        removeRecoveryJournal(journal)
      }
    case let .quotariRegistry(id):
      // A captured account Quotari owns: refresh keeps the stored snapshot's
      // token alive so the account stays usable while it's not the live one.
      // The merge runs inside updatePayload's mutation lock so the stale-token
      // guard is atomic with the write — a concurrent re-capture can't be
      // clobbered by a merge based on the pair it just replaced.
      guard capturedAccounts.account(id: id) != nil else {
        throw ClaudeCredentialPersistError.sourceUnavailable
      }
      try capturedAccounts.updatePayload(id: id) { payload in
        try merge(grant, replacing: previousAccessToken, into: payload)
      }
    case .codexAuthFile:
      throw ClaudeCredentialPersistError.sourceUnavailable
    }
  }

  func merge(_ grant: ClaudeTokenGrant, replacing previousAccessToken: String, into data: Data) throws -> Data {
    guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var oauth = root["claudeAiOauth"] as? [String: Any]
    else { throw ClaudeCredentialPersistError.malformedPayload }
    guard oauth["accessToken"] as? String == previousAccessToken else {
      throw ClaudeCredentialPersistError.staleSource
    }
    oauth["accessToken"] = grant.accessToken
    if let refreshToken = grant.refreshToken {
      oauth["refreshToken"] = refreshToken
    }
    if let expiresAt = grant.expiresAt {
      oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
    } else {
      // Keeping the old expiry would make the next load refresh immediately
      // while the in-memory pair reports no expiry; drop it so both agree.
      oauth.removeValue(forKey: "expiresAt")
    }
    if let scopes = grant.scopes {
      // The server's scope answer is authoritative; requesting stale scopes
      // on the next refresh would fail once the grant narrows.
      oauth["scopes"] = scopes
    }
    root["claudeAiOauth"] = oauth
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }
}

private extension ClaudeCredentialsWriter {
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
  }

  struct MirrorRecoveryJournal {
    var id: String
    var pending: ClaudePendingGrant
    var previous: ClaudePendingGrant?
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
          FileManager.default.fileExists(atPath: destination.path),
          let id = ProviderCredentialSource
          .claudeCredentialsFile(path: destination.standardizedFileURL.path)
          .claudeLivePendingGrantID
    else { return MirrorRecovery(preparation: initial, journal: nil) }

    switch initial {
    case .none:
      // The file may be one rotation behind the canonical keychain. Only an
      // exact existing journal can bridge that lineage; an unrelated file is
      // intentionally left alone.
      guard let existing = try loadRecoveryJournal(id: id) else {
        return MirrorRecovery(preparation: initial, journal: nil)
      }
      let effective: ClaudePendingGrant
      if let merged = pending.mergingLineage(with: existing) {
        effective = merged
      } else if let chained = pending.chaining(after: existing) {
        // Chaining takes precedence even when the predecessor was marked as
        // backed up: it may still be the only bridge to a stale file.
        effective = chained
      } else {
        return MirrorRecovery(preparation: initial, journal: nil)
      }
      let preparation = reprepareMirror(
        discarding: initial,
        grant,
        replacing: previousAccessToken,
        pending: effective,
        keychainService: keychainService
      )
      guard preparation.requiresJournal else {
        return MirrorRecovery(preparation: preparation, journal: nil)
      }
      return MirrorRecovery(
        preparation: preparation,
        journal: MirrorRecoveryJournal(id: id, pending: effective, previous: existing)
      )

    case .failed, .prepared:
      let existing = try loadRecoveryJournal(id: id)
      let effective: ClaudePendingGrant
      if let existing {
        if existing == pending {
          effective = pending
        } else if let merged = pending.mergingLineage(with: existing) {
          effective = merged
        } else if let chained = pending.chaining(after: existing) {
          effective = chained
        } else if existing.liveSourceBackupRecorded == true {
          // A marked record that cannot bridge the current generation is only
          // cleanup debt whose resolved generation was backed up durably.
          effective = pending
        } else {
          throw ClaudeCredentialPersistError.recoveryJournalFailed(
            underlying: "A different unbacked grant already owns the mirrored credential source."
          )
        }
      } else {
        effective = pending
      }
      let preparation = effective == pending ? initial : reprepareMirror(
        discarding: initial,
        grant,
        replacing: previousAccessToken,
        pending: effective,
        keychainService: keychainService
      )
      guard preparation.requiresJournal else {
        return MirrorRecovery(preparation: preparation, journal: nil)
      }
      return MirrorRecovery(
        preparation: preparation,
        journal: MirrorRecoveryJournal(id: id, pending: effective, previous: existing)
      )
    }
  }

  func reprepareMirror(
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
  func preparedMirror(
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

  func commitPreparedMirrorIfUnchanged(
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

  func mirrorAccessToken(
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

  /// The canonical journal exists only across the keychain write. The file
  /// journal has a separate id and survives until its mirror commit succeeds.
  func canonicalRecoveryJournal(
    pending: ClaudePendingGrant?,
    keychainService: String
  ) throws -> MirrorRecoveryJournal? {
    guard let pending,
          let id = ProviderCredentialSource
          .claudeKeychain(service: keychainService)
          .claudeLivePendingGrantID
    else { return nil }
    guard let existing = try loadRecoveryJournal(id: id) else {
      return MirrorRecoveryJournal(id: id, pending: pending, previous: nil)
    }
    let effective: ClaudePendingGrant
    if existing == pending {
      effective = pending
    } else if let merged = pending.mergingLineage(with: existing) {
      effective = merged
    } else if let chained = pending.chaining(after: existing) {
      effective = chained
    } else if existing.liveSourceBackupRecorded == true {
      effective = pending
    } else {
      throw ClaudeCredentialPersistError.recoveryJournalFailed(
        underlying: "A different unbacked grant already owns the canonical credential source."
      )
    }
    return MirrorRecoveryJournal(id: id, pending: effective, previous: existing)
  }

  /// Installs or advances an exact source journal before publishing the
  /// canonical keychain generation. A concurrent unbacked owner wins.
  func installRecoveryJournal(_ journal: MirrorRecoveryJournal) throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(journal.pending)
      let installed: Bool
      if let previous = journal.previous {
        installed = try capturedAccounts.replacePendingGrant(
          id: journal.id,
          when: { current in
            try JSONDecoder().decode(ClaudePendingGrant.self, from: current) == previous
          },
          with: data
        )
      } else {
        installed = try capturedAccounts.saveLivePendingGrantIfAbsent(data, id: journal.id)
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

  func removeRecoveryJournal(_ journal: MirrorRecoveryJournal) {
    do {
      _ = try capturedAccounts.removePendingGrant(id: journal.id) { data in
        try JSONDecoder().decode(ClaudePendingGrant.self, from: data) == journal.pending
      }
    } catch {
      Self.logger.error(
        "Cleaning up Claude's mirrored recovery journal failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
