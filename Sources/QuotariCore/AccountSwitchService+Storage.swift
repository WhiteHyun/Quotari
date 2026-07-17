import Foundation

extension AccountSwitchService {
  // MARK: - Reads (fail closed: a read failure is never mistaken for absence)

  func readKeychain(_ service: String) throws -> Data? {
    do {
      return try keychainRead(service)
    } catch {
      throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
    }
  }

  /// Aborts the switch when the Codex slot exists but is group/world-readable
  /// — the same bearer-token exposure the capture path refuses. A missing
  /// slot is fine (nothing to protect).
  func requireSecureCodexSlot(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path),
          let posix = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    else { return }
    if posix.intValue & 0o077 != 0 {
      throw AccountSwitchError.backupFailed(underlying: CodexCredentialsError.insecurePermissions.localizedDescription)
    }
  }

  /// `nil` only for a genuinely absent file; a file that exists but can't be
  /// read throws (aborting the switch rather than treating it as empty).
  func readFile(_ url: URL) throws -> Data? {
    do {
      return try credentialFileRead(url)
    } catch {
      throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
    }
  }

  // MARK: - Backup

  /// Captures the login currently in a slot so the switch never destroys it.
  /// An empty or non-OAuth slot has nothing durable to preserve and proceeds;
  /// an OAuth login that cannot be captured aborts before it is overwritten.
  /// Backs up `payload` (Claude) and returns it, so a switch step can read,
  /// preserve, and thread the value through in one expression.
  func backedUpSlot(
    _ payload: Data?,
    origin: ProviderCredentialSource,
    now: Date,
    refreshingTargetID: String?,
    claudeOAuthAccount: Data? = nil
  ) throws -> Data? {
    try backUp(
      provider: .claude,
      payload: payload,
      origin: origin,
      now: now,
      refreshingTargetID: refreshingTargetID,
      claudeOAuthAccount: claudeOAuthAccount
    )
    return payload
  }

  func backUp(
    provider: UsageProvider,
    payload: Data?,
    origin: ProviderCredentialSource,
    now: Date,
    refreshingTargetID: String? = nil,
    claudeOAuthAccount: Data? = nil
  ) throws {
    guard let payload else { return }
    // Renewability — not a resolvable identity — is the bar: a renewable
    // Codex login with no account_id/email is still worth preserving (normal
    // Save keeps it under a UUID), so back it up rather than overwrite it.
    // A recognized access-token-only OAuth login cannot be preserved beyond
    // expiry, but it is still the user's current login; fail closed instead
    // of silently destroying it. An API-key-only Codex slot is safe because
    // the transplant preserves OPENAI_API_KEY as an unrelated root sibling.
    guard ProviderCredentialMinimizer.minimize(provider: provider, payload: payload) != nil else {
      if ProviderCredentialMinimizer.hasAccessToken(provider: provider, payload: payload) {
        throw AccountSwitchError.backupFailed(
          underlying: AccountCaptureError.noRefreshToken.localizedDescription
        )
      }
      return
    }
    do {
      if let refreshingTargetID {
        try capture.refreshCapturedAccount(
          id: refreshingTargetID,
          provider: provider,
          payload: payload,
          claudeOAuthAccount: claudeOAuthAccount
        )
      } else {
        try capture.captureRawPayload(
          provider: provider,
          origin: origin,
          payload: payload,
          now: now,
          claudeOAuthAccount: claudeOAuthAccount
        )
      }
    } catch {
      throw AccountSwitchError.backupFailed(underlying: error.localizedDescription)
    }
  }

  func prepareCredentialFile(_ data: Data?, replacing destination: URL) throws -> URL? {
    do {
      return try data.map { try secureFileWriter.prepare($0, replacing: destination) }
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
  }

  struct ClaudeSlots {
    var service: String
    var fileURL: URL
    var fileSource: ProviderCredentialSource
    var keychain: Data?
    var file: Data?
    var pendingGrants: [ClaudeLivePendingGrant]
  }
}
