import Foundation

public enum AccountSwitchWarning: Sendable, Equatable {
  case cliSessionResumeFailed(underlying: String)

  public var message: String {
    switch self {
    case let .cliSessionResumeFailed(underlying):
      "The CLI account switched, but Quotari couldn't resume every paused Claude session: "
        + underlying
    }
  }
}

public struct AccountSwitchResult: Sendable, Equatable {
  public var credentialSource: ProviderCredentialSource
  public var warning: AccountSwitchWarning?

  public init(
    credentialSource: ProviderCredentialSource,
    warning: AccountSwitchWarning? = nil
  ) {
    self.credentialSource = credentialSource
    self.warning = warning
  }
}

public extension AccountSwitchService {
  /// Performs the switch and returns the credential source it wrote plus any
  /// post-switch session-recovery warning. The source is the live slot the CLI
  /// now reads (Claude keychain, or Codex's resolved file or keychain backend).
  /// The caller selects the discovered live row with exactly this source, so a
  /// recovery warning never leaves the UI pointing at the previous login.
  @discardableResult
  func switchCLI(
    toRegistryAccount id: String,
    now: Date,
    knownLiveTarget: KnownLiveClaudeTarget? = nil,
    targetClaudeProfile: ClaudeProfile? = nil,
    verifiedLiveClaudeIdentity: VerifiedLiveClaudeIdentity? = nil,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot? = nil
  ) throws -> AccountSwitchResult {
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
    if provider == .claude, let activitySnapshot, activitySnapshot.isActive {
      return try CLIActivityApprovalContext.$snapshot.withValue(activitySnapshot) {
        let result = try withSuspendedApprovedCLIProcesses(
          activitySnapshot,
          provider: provider,
          operation: performSwitch
        )
        return AccountSwitchResult(
          credentialSource: result.value,
          warning: result.warning
        )
      }
    }
    // Active-session approval is a Claude-only capability. In particular, a
    // direct Codex caller cannot install an approval snapshot without also
    // entering a suspension implementation.
    return try CLIActivityApprovalContext.$snapshot.withValue(nil) {
      try AccountSwitchResult(credentialSource: performSwitch())
    }
  }
}
