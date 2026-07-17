import Foundation

extension AccountSwitchService {
  /// Associates `.claude.json.oauthAccount` only with the exact canonical
  /// credential generation observed beside it. Claude Code reads the
  /// Keychain before the credentials file, so a divergent lower-precedence
  /// file must not inherit the active terminal identity.
  func stableClaudeOAuthAccount(
    matching slots: ResolvedClaudeLivePayloads,
    service: String,
    fileURL: URL
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
    return oauthAccount
  }
}
