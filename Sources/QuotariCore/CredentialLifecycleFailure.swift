import Foundation

public extension CredentialLifecycleEvent.Failure {
  static func classify(_ error: Error) -> Self {
    let error = (error as? ProviderFetchTransitionError)?.underlying ?? error
    if error is CancellationError {
      return .cancelled
    }
    if let failure = classifyRefresh(error) {
      return failure
    }
    if let failure = classifyHTTP(error) {
      return failure
    }
    if let failure = classifyFetch(error) {
      return failure
    }
    if let failure = classifySwitch(error) {
      return failure
    }
    return .unknown
  }

  private static func classifyRefresh(_ error: Error) -> Self? {
    if let refreshError = error as? ClaudeTokenRefreshError,
       refreshError.requiresReauthentication {
      return .reauthenticationRequired
    }
    if error is CodexTokenRefreshError || error is ClaudeTokenRefreshError {
      return .malformedResponse
    }
    return nil
  }

  private static func classifyHTTP(_ error: Error) -> Self? {
    guard let error = error as? ProviderHTTPError else { return nil }
    return switch error {
    case .unauthorized: .unauthorized
    case .rateLimited: .rateLimited
    case .nonHTTPResponse, .status: .inputOutput
    }
  }

  private static func classifyFetch(_ error: Error) -> Self? {
    guard let error = error as? ProviderFetchError else { return nil }
    return switch error {
    case .selectedCredentialUnavailable, .missingCredential: .credentialUnavailable
    case .noStrategyAvailable, .emptyUsage: .unknown
    }
  }

  private static func classifySwitch(_ error: Error) -> Self? {
    guard let error = error as? AccountSwitchError else { return nil }
    return switch error {
    case .cliStillRunning: .cliActive
    case .concurrentCredentialChange: .concurrentCredentialChange
    case .claudeAccountIdentityUnavailable: .verification
    case .accountNotFound: .credentialUnavailable
    case .cliActivityCheckFailed, .slotReadFailed, .backupFailed, .writeFailed, .partialSwitch: .inputOutput
    }
  }
}
