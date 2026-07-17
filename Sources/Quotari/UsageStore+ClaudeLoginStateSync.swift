import Foundation
import QuotariCore

extension UsageStore {
  func resolvedClaudeOAuthAccount(candidate: Data?, profile: ClaudeProfile) -> Data? {
    if let candidate, ClaudeCodeAccountState.matches(candidate, profile: profile) {
      return candidate
    }
    return try? ClaudeCodeAccountState.synthesizedOAuthAccount(
      for: profile,
      template: candidate
    )
  }

  func captureAccountLoginResult(
    _ result: AccountLoginResult,
    verifiedClaudeProfile: ClaudeProfile?,
    claudeOAuthAccount: Data?
  ) async throws -> CapturedAccount {
    let capture = accountCapture
    let captured = try await Task.detached {
      try capture.captureRawPayload(
        provider: result.provider,
        origin: result.origin,
        payload: result.payload,
        now: Date(),
        claudeOAuthAccount: claudeOAuthAccount
      )
    }.value
    guard let captured else { throw AddedAccountImportError.notRenewable }
    if let verifiedClaudeProfile {
      storeClaudeLoginProfile(verifiedClaudeProfile, for: captured)
    }
    return captured
  }

  func synchronizeClaudeLoginState(
    _ captured: CapturedAccount,
    source: ProviderCredentialSource,
    credentialFingerprint: String,
    profile: ClaudeProfile?
  ) async throws {
    let switcher = accountSwitch
    _ = try await Task.detached {
      try switcher.switchCLI(
        toRegistryAccount: captured.id,
        now: Date(),
        knownLiveTarget: KnownLiveClaudeTarget(
          source: source,
          accessTokenFingerprint: credentialFingerprint
        ),
        targetClaudeProfile: profile
      )
    }.value
  }
}
