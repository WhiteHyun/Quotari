import Foundation
import QuotariCore

indirect enum AutomaticAccountCapturePlan: Sendable {
  case capture
  case captureClaude(accessTokenFingerprint: String, profile: ClaudeProfile)
  case refreshClaude(
    id: String,
    savedOrigin: ProviderAccount,
    accessTokenFingerprint: String,
    profile: ClaudeProfile,
    redundantAccounts: [CapturedAccount] = []
  )
  case ignoreDuplicate(
    savedOrigin: ProviderAccount?,
    canonicalCandidateID: String?,
    fallbackCapturePlan: AutomaticAccountCapturePlan?
  )
  case blocked(String)

  func capture(
    _ account: ProviderAccount,
    using service: AccountCaptureService,
    now: Date
  ) throws -> CapturedAccount? {
    switch self {
    case .capture:
      try service.capture(account, now: now)
    case let .captureClaude(fingerprint, profile):
      try service.captureClaudeAccount(
        account,
        expectedAccessTokenFingerprint: fingerprint,
        profile: profile,
        now: now
      )
    case let .refreshClaude(id, _, fingerprint, profile, _):
      try service.refreshCapturedClaudeAccount(
        id: id,
        from: account,
        expectedAccessTokenFingerprint: fingerprint,
        profile: profile
      )
    case .ignoreDuplicate:
      nil
    case let .blocked(message):
      throw AutomaticAccountCapturePlanError.blocked(message)
    }
  }

  func savedClaudeIdentity(captured: CapturedAccount?) -> (id: String, profile: ClaudeProfile)? {
    switch self {
    case let .captureClaude(fingerprint, profile):
      guard let captured,
            let accessToken = ProviderCredentialIdentity.discoveredAccountIdentity(
              provider: .claude,
              payload: captured.payload
            ),
            ProviderCredentialIdentity.fingerprint(of: accessToken) == fingerprint
      else { return nil }
      return (captured.id, profile)
    case let .refreshClaude(id, _, fingerprint, profile, _):
      guard let captured,
            let accessToken = ProviderCredentialIdentity.discoveredAccountIdentity(
              provider: .claude,
              payload: captured.payload
            ),
            ProviderCredentialIdentity.fingerprint(of: accessToken) == fingerprint
      else { return nil }
      return (id, profile)
    case .capture, .ignoreDuplicate, .blocked:
      return nil
    }
  }

  var isIgnoredDuplicate: Bool {
    if case .ignoreDuplicate = self {
      return true
    }
    return false
  }

  var duplicateSavedOrigin: ProviderAccount? {
    switch self {
    case let .refreshClaude(_, savedOrigin, _, _, _): savedOrigin
    case let .ignoreDuplicate(savedOrigin, _, _): savedOrigin
    case .capture, .captureClaude, .blocked: nil
    }
  }

  var canonicalCandidateID: String? {
    guard case let .ignoreDuplicate(_, canonicalCandidateID, _) = self else { return nil }
    return canonicalCandidateID
  }

  var fallbackCapturePlan: AutomaticAccountCapturePlan? {
    guard case let .ignoreDuplicate(_, _, fallbackCapturePlan) = self else { return nil }
    return fallbackCapturePlan
  }

  var redundantClaudeAccounts: [CapturedAccount] {
    guard case let .refreshClaude(_, _, _, _, redundantAccounts) = self else { return [] }
    return redundantAccounts
  }
}

private enum AutomaticAccountCapturePlanError: LocalizedError {
  case blocked(String)

  var errorDescription: String? {
    guard case let .blocked(message) = self else { return nil }
    return message
  }
}

extension ProviderCredentialSource {
  var isAutomaticallyCapturable: Bool {
    switch self {
    case .codexAuthFile, .codexKeychain, .claudeKeychain, .claudeCredentialsFile:
      true
    case .claudeEnvironment, .quotariRegistry:
      false
    }
  }
}
