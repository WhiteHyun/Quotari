/// A live Claude source whose current access-token generation was verified
/// against the saved account's profile immediately before a switch. The
/// service rechecks the fingerprint on every slot read before it may refresh
/// that saved registry row in place.
public struct KnownLiveClaudeTarget: Equatable, Sendable {
  public var source: ProviderCredentialSource
  public var accessTokenFingerprint: String

  public init(source: ProviderCredentialSource, accessTokenFingerprint: String) {
    self.source = source
    self.accessTokenFingerprint = accessTokenFingerprint
  }
}

/// Account identity evidence fetched for the exact Claude credential that is
/// currently canonical. A stable `.claude.json` snapshot alone is not enough:
/// after an external login, the credential can advance before Claude Code
/// refreshes that file. The switch rechecks all three fields before attaching
/// the terminal identity to a newly backed-up credential.
public struct VerifiedLiveClaudeIdentity: Equatable, Sendable {
  public var source: ProviderCredentialSource
  public var accessTokenFingerprint: String
  public var profile: ClaudeProfile

  public init(
    source: ProviderCredentialSource,
    accessTokenFingerprint: String,
    profile: ClaudeProfile
  ) {
    self.source = source
    self.accessTokenFingerprint = accessTokenFingerprint
    self.profile = profile
  }
}
