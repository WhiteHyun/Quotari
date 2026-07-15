import Foundation
import QuotariCore

extension UsageStore {
  func canAddAccount(for provider: UsageProvider) -> Bool {
    accountLogin.supports(provider: provider)
  }

  func addAccountUnavailableReason(for provider: UsageProvider) -> String? {
    accountLogin.unavailableReason(provider: provider)
  }

  func addAccount(for provider: UsageProvider) async {
    guard addingAccountProviders.isEmpty else {
      accountLoginErrors[provider] = "Finish the account login already in progress before starting another one."
      return
    }

    addingAccountProviders.insert(provider)
    accountLoginErrors[provider] = nil
    accountLoginOutputs[provider] = nil
    defer { addingAccountProviders.remove(provider) }

    // The scan is the preservation boundary: every renewable login already in
    // a live CLI slot must be managed before a second login is allowed to open.
    await reloadAccounts()
    guard captureErrors[provider] == nil else {
      accountLoginErrors[provider] =
        "Quotari couldn’t preserve the current CLI account. Resolve the account scan error, then try again."
      return
    }

    let login = accountLogin
    let capture = accountCapture
    do {
      let result = try await login.login(provider: provider) { [weak self] output in
        await self?.appendAccountLoginOutput(output, for: provider)
      }
      let captured = try await Task.detached {
        try capture.captureRawPayload(
          provider: result.provider,
          origin: result.origin,
          payload: result.payload,
          now: Date()
        )
      }.value
      guard captured != nil else {
        throw AddedAccountImportError.notRenewable
      }
      await reloadAccounts()
      accountLoginErrors[provider] = nil
      accountLoginOutputs[provider] = nil
    } catch is CancellationError {
      accountLoginErrors[provider] = "Account login was cancelled."
    } catch {
      accountLoginErrors[provider] = error.localizedDescription
    }
  }

  private func appendAccountLoginOutput(_ output: String, for provider: UsageProvider) {
    let combined = (accountLoginOutputs[provider] ?? "") + output
    accountLoginOutputs[provider] = String(combined.suffix(12000))
  }
}

private enum AddedAccountImportError: LocalizedError {
  case notRenewable

  var errorDescription: String? {
    "The new login didn’t provide a renewable credential, so Quotari didn’t add it."
  }
}
