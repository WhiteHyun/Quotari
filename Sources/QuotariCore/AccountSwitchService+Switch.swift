import Foundation

public extension AccountSwitchService {
  /// Performs the switch and returns the live slot the CLI now reads (Claude
  /// keychain, or Codex's resolved file or keychain backend). The caller uses
  /// this exact source to select the discovered switched-in account.
  @discardableResult
  func switchCLI(
    toRegistryAccount id: String,
    now: Date,
    knownLiveTarget: KnownLiveClaudeTarget? = nil,
    targetClaudeProfile: ClaudeProfile? = nil,
    verifiedLiveClaudeIdentity: VerifiedLiveClaudeIdentity? = nil
  ) throws -> ProviderCredentialSource {
    let provider = capturedAccounts.account(id: id)?.provider
    guard let provider else {
      throw AccountSwitchError.accountNotFound
    }
    let performSwitch = {
      try requireCLIInactive(provider)
      switch provider {
      case .claude:
        return try switchClaude(
          registryID: id,
          now: now,
          knownLiveTarget: knownLiveTarget,
          targetProfile: targetClaudeProfile,
          verifiedLiveIdentity: verifiedLiveClaudeIdentity
        )
      case .codex:
        return try switchCodex(registryID: id, now: now)
      }
    }
    // Account login may install a task-local approval for sessions that were
    // already running before its browser flow. A CLI switch must never inherit
    // that approval: every active provider session blocks credential mutation.
    return try CLIActivityApprovalContext.$snapshot.withValue(nil) {
      try performSwitch()
    }
  }
}
