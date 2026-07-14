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
  static let logger = Logger(subsystem: "com.quotari.QuotariCore", category: "claude-credentials")

  let keychainRead: @Sendable (String) -> Data?
  let keychainWrite: @Sendable (Data, String) throws -> Void
  let capturedAccounts: CapturedAccountStore
  let mirroredCredentialsFileURL: URL?
  let fileRead: @Sendable (URL) throws -> Data
  let secureFileWriter: SecureCredentialFileWriter
  let commitMirroredFile: @Sendable (URL, URL) throws -> Void

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
      try persistToKeychain(grant, replacing: previousAccessToken, service: service)
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
    case .codexAuthFile, .codexKeychain:
      throw ClaudeCredentialPersistError.sourceUnavailable
    }
  }

  private func persistToKeychain(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    service: String
  ) throws {
    guard let data = keychainRead(service) else { throw ClaudeCredentialPersistError.sourceUnavailable }
    if try repairInstalledMirrorIfNeeded(
      grant,
      replacing: previousAccessToken,
      canonicalPayload: data,
      keychainService: service
    ) {
      return
    }
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
    let mirrorResolved = commitMirrorIfUnchanged(
      recovery.preparation,
      pending: recovery.journal?.pending ?? pending
    )
    if mirrorResolved {
      try finishMirrorRecovery(recovery, canonicalJournal: canonicalJournal)
      return
    }
    throw ClaudeCredentialPersistError.recoveryJournalFailed(
      underlying: "The canonical keychain grant is installed, but its credentials file mirror is still pending."
    )
  }

  private func finishMirrorRecovery(
    _ recovery: MirrorRecovery,
    canonicalJournal: MirrorRecoveryJournal?
  ) throws {
    let mirrorJournalsResolved = removeResolvedMirrorJournals(recovery)
    guard let canonicalJournal else { return }
    guard mirrorJournalsResolved, removeRecoveryJournal(canonicalJournal) else {
      throw ClaudeCredentialPersistError.recoveryJournalFailed(
        underlying: "The mirror is updated, but its recovery journal cleanup is still pending."
      )
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
