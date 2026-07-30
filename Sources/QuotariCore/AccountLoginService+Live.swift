import Foundation

extension AccountLoginService {
  static func performLiveLogin(_ request: AccountLoginRequest) async throws -> AccountLoginResult {
    switch request.provider {
    case .claude:
      try await LiveClaudeAccountLogin.perform(
        beforeCredentialOverwrite: { payload in
          try await request.preserveCredential?(
            .claude,
            .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
            payload
          )
        },
        duringLoginCredentialChange: { payload in
          try await request.preserveCredentialDuringLogin?(
            .claude,
            .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
            payload
          )
        },
        onLoginStarted: request.credentialMutation,
        onCredentialObserved: request.credentialObservation,
        onOutput: request.onOutput,
        input: request.input,
        allowingActiveSessions: request.activitySnapshot
      )
    case .codex:
      try await IsolatedAccountLogin.perform(
        provider: request.provider,
        onOutput: request.onOutput,
        input: request.input
      )
    }
  }
}
