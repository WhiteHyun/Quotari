import Foundation

extension AccountSwitchService {
  /// Associates `.claude.json.oauthAccount` only with a canonical credential
  /// whose exact access-token generation was independently profile-verified.
  /// Merely observing stable credential and state bytes is insufficient: an
  /// external login can replace the credential before Claude Code refreshes
  /// its terminal identity file.
  func stableClaudeOAuthAccount(
    matching slots: ResolvedClaudeLivePayloads,
    service: String,
    fileURL: URL,
    verifiedLiveIdentity: VerifiedLiveClaudeIdentity?
  ) throws -> Data? {
    let stateURL = ClaudeCodeAccountState.configurationURL(environment: environment, home: home)
    let state = try readFile(stateURL)
    let oauthAccount: Data?
    do {
      oauthAccount = try ClaudeCodeAccountState.oauthAccount(from: state)
    } catch {
      throw AccountSwitchError.backupFailed(underlying: error.localizedDescription)
    }
    guard try readKeychain(service) == slots.keychain,
          try readFile(fileURL) == slots.file,
          try readFile(stateURL) == state
    else { throw AccountSwitchError.concurrentCredentialChange }
    guard let oauthAccount,
          let verifiedLiveIdentity,
          let canonical = canonicalClaudeCredential(
            in: slots,
            service: service,
            fileURL: fileURL
          ),
          canonical.source == verifiedLiveIdentity.source,
          ProviderCredentialIdentity.fingerprint(of: canonical.credentials.accessToken)
          == verifiedLiveIdentity.accessTokenFingerprint,
          verifiedLiveIdentity.profile.fingerprint == verifiedLiveIdentity.accessTokenFingerprint,
          ClaudeCodeAccountState.matches(oauthAccount, profile: verifiedLiveIdentity.profile)
    else { return nil }
    return oauthAccount
  }

  private func canonicalClaudeCredential(
    in slots: ResolvedClaudeLivePayloads,
    service: String,
    fileURL: URL
  ) -> (source: ProviderCredentialSource, credentials: ClaudeCredentials)? {
    if let keychain = slots.keychain,
       let credentials = try? ClaudeCredentialsStore.parse(keychain) {
      return (.claudeKeychain(service: service), credentials)
    }
    if let file = slots.file,
       let credentials = try? ClaudeCredentialsStore.parse(file) {
      return (
        .claudeCredentialsFile(path: fileURL.standardizedFileURL.path),
        credentials
      )
    }
    return nil
  }
}
