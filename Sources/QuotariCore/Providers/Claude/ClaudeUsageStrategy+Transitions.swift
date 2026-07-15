import Foundation

extension ClaudeUsageStrategy {
  func credentialTransitionSourceScopeIDs(
    _ acceptedGrant: ClaudePendingGrant?,
    source: ProviderCredentialSource
  ) -> Set<String> {
    guard let acceptedGrant else { return [] }
    return Set(
      ([acceptedGrant.previousAccessToken] + (acceptedGrant.priorAccessTokens ?? [])).map { token in
        ProviderAccount(
          provider: .claude,
          displayName: "Claude Code",
          detail: nil,
          credentialSource: source,
          credentialIdentity: token
        ).credentialScopeID
      }
    )
  }
}
