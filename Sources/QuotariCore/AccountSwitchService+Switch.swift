import Foundation

public extension AccountSwitchService {
  /// Performs the switch and returns the credential source it wrote — the
  /// live slot the CLI now reads (Claude keychain, or Codex's resolved file or
  /// keychain backend). The caller selects the discovered live row with exactly
  /// this source, so usage/refresh follow the store that was switched rather
  /// than a duplicate slot or the registry copy.
  @discardableResult
  func switchCLI(
    toRegistryAccount id: String,
    now: Date,
    knownLiveTarget: KnownLiveClaudeTarget? = nil,
    targetClaudeProfile: ClaudeProfile? = nil,
    verifiedLiveClaudeIdentity: VerifiedLiveClaudeIdentity? = nil
  ) throws -> ProviderCredentialSource {
    let provider = capturedAccounts.account(id: id)?.provider
    if let provider {
      // A long-lived CLI can rotate the shared credential again after this
      // synchronous operation returns. Unlike the bounded login window, an
      // account switch has no safe lifetime monitor, so it never authorizes
      // active sessions to outlive the write.
      try requireCLIInactive(provider)
    }
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
    case nil:
      throw AccountSwitchError.accountNotFound
    }
  }
}
