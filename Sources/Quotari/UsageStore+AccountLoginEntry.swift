import QuotariCore

extension UsageStore {
  func startAddingAccount(
    for provider: UsageProvider,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot? = nil
  ) {
    guard accountLoginTasks[provider] == nil else { return }
    accountLoginTasks[provider] = Task { [weak self] in
      guard let self else { return }
      await addAccount(for: provider, allowingActiveSessions: activitySnapshot)
      accountLoginTasks[provider] = nil
    }
  }

  func cancelAccountLogin(for provider: UsageProvider) {
    accountLoginTasks[provider]?.cancel()
  }

  func canAddAccount(for provider: UsageProvider) -> Bool {
    accountLogin.supports(provider: provider)
  }

  func addAccountUnavailableReason(for provider: UsageProvider) -> String? {
    accountLogin.unavailableReason(provider: provider)
  }

  func canBeginAccountLogin(for provider: UsageProvider) -> Bool {
    guard addingAccountProviders.isEmpty else {
      accountLoginErrors[provider] = L10n.string(
        "Finish the account login already in progress before starting another one."
      )
      return false
    }
    guard !isSwitching else {
      accountLoginErrors[provider] = L10n.string(
        "Finish the account switch already in progress before starting a new login."
      )
      return false
    }
    return true
  }
}
