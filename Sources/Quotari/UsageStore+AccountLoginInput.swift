import Foundation
import QuotariCore

extension UsageStore {
  @discardableResult
  func submitAccountLoginAuthenticationCode(_ code: String, for provider: UsageProvider) -> Bool {
    guard accountLoginPhases[provider] == .waitingForAuthenticationCode,
          let input = accountLoginInputs[provider]
    else {
      accountLoginErrors[provider] = AccountLoginInputError.inputUnavailable.localizedDescription
      return false
    }
    do {
      try input.submit(authenticationCode: code)
      accountLoginErrors[provider] = nil
      accountLoginPhases[provider] = .completingLogin
      return true
    } catch {
      accountLoginErrors[provider] = error.localizedDescription
      return false
    }
  }

  func performAccountLogin(
    for provider: UsageProvider,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline?
  ) async throws -> AccountLoginResult {
    accountLoginPhases[provider] = .waitingForBrowser
    let input = AccountLoginInput()
    accountLoginInputs[provider] = input
    defer { accountLoginInputs[provider] = nil }
    let login = accountLogin
    return try await login.login(
      provider: provider,
      onOutput: { [weak self] output in
        await self?.appendAccountLoginOutput(output, for: provider)
      },
      input: input,
      beforeCredentialOverwrite: { [weak self] provider, source, payload in
        guard let self else { throw CancellationError() }
        try await preserveCredentialImmediatelyBeforeLogin(
          provider: provider,
          source: source,
          payload: payload,
          previousClaudeLogin: previousClaudeLogin,
          registryBaseline: registryBaseline
        )
      },
      onCredentialMutationPossible: {
        registryBaseline?.markCredentialMutationPossible()
      }
    )
  }

  private func appendAccountLoginOutput(_ output: String, for provider: UsageProvider) {
    let combined = (accountLoginOutputs[provider] ?? "") + output
    accountLoginOutputs[provider] = String(combined.suffix(12000))
    if accountLoginPhases[provider] == .waitingForBrowser,
       combined.localizedCaseInsensitiveContains("Paste code here") {
      accountLoginPhases[provider] = .waitingForAuthenticationCode
    }
  }
}
