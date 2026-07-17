import Foundation

extension AccountSwitchService {
  func claudeAccountStateInstallation(
    registryID: String,
    targetProfile: ClaudeProfile?
  ) throws -> ClaudeAccountStateInstallation? {
    guard let saved = capturedAccounts.account(id: registryID) else {
      throw AccountSwitchError.accountNotFound
    }
    guard saved.claudeOAuthAccount != nil || targetProfile != nil else {
      throw AccountSwitchError.claudeAccountIdentityUnavailable
    }
    let url = home.appendingPathComponent(".claude.json")
    let previous = try readFile(url)
    let template: Data?
    do {
      template = try ClaudeCodeAccountState.oauthAccount(from: previous)
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }

    let oauthAccount: Data?
    if let exact = saved.claudeOAuthAccount,
       targetProfile.map({ ClaudeCodeAccountState.matches(exact, profile: $0) }) ?? true {
      oauthAccount = exact
    } else if let targetProfile {
      do {
        oauthAccount = try ClaudeCodeAccountState.synthesizedOAuthAccount(
          for: targetProfile,
          template: template
        )
      } catch {
        throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
      }
    } else {
      oauthAccount = nil
    }
    guard let oauthAccount else { return nil }
    do {
      return try ClaudeAccountStateInstallation(
        url: url,
        previous: previous,
        replacement: ClaudeCodeAccountState.replacingOAuthAccount(
          in: previous,
          with: oauthAccount
        )
      )
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
  }
}
