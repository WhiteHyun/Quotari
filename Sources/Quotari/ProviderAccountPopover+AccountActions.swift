import QuotariCore
import SwiftUI

extension ProviderAccountPopover {
  func perform(_ action: ProviderAccountPopoverAction, for account: ProviderAccount) {
    switch action {
    case .selectDashboard:
      store.selectAccount(account, for: descriptor.id)
      dismiss()
    case .switchCLI:
      requestSwitchingCLI(to: account)
    }
  }

  func requestSwitchingCLI(to account: ProviderAccount) {
    guard account.provider == .claude else {
      startSwitchingCLI(to: account)
      return
    }
    guard cliActivityInspection.begin() else { return }
    Task {
      defer { cliActivityInspection.finish() }
      do {
        let activitySnapshot = try await store.cliActivitySnapshot(for: account.provider)
        if activitySnapshot.isActive {
          confirmation = .switchBlocked(account, activitySnapshot)
        } else {
          confirmation = nil
          startSwitchingCLI(to: account)
        }
      } catch {
        confirmation = nil
        store.captureErrors[account.provider] = AccountSwitchError.cliActivityCheckFailed(
          underlying: error.localizedDescription
        ).localizedDescription
      }
    }
  }

  func startSwitchingCLI(to account: ProviderAccount) {
    Task {
      let shouldDismiss = await switchCoordinator.switchCLI(to: account) {
        await store.switchCLIAccount(to: account)
        return store.captureErrors[account.provider] == nil
      }
      if shouldDismiss {
        dismiss()
      }
    }
  }

  func requestAddingAccount() {
    guard descriptor.id == .claude else {
      store.startAddingAccount(for: descriptor.id)
      return
    }
    guard cliActivityInspection.begin() else { return }
    Task {
      defer { cliActivityInspection.finish() }
      do {
        let activitySnapshot = try await store.cliActivitySnapshot(for: descriptor.id)
        if activitySnapshot.isActive {
          confirmation = .addClaudeAccount(activitySnapshot)
        } else {
          store.startAddingAccount(for: descriptor.id)
        }
      } catch {
        store.accountLoginErrors[descriptor.id] = AccountLoginError.cliActivityCheckFailed(
          descriptor.id,
          underlying: error.localizedDescription
        ).localizedDescription
      }
    }
  }

  func performConfirmedOperation(_ confirmation: ProviderAccountPopoverConfirmation) {
    switch confirmation {
    case let .addClaudeAccount(activitySnapshot):
      self.confirmation = nil
      store.startAddingAccount(
        for: .claude,
        allowingActiveSessions: activitySnapshot
      )
    case let .switchBlocked(account, _):
      requestSwitchingCLI(to: account)
    }
  }
}

enum ProviderAccountPopoverConfirmation: Identifiable {
  case addClaudeAccount(CLIActivitySnapshot)
  case switchBlocked(ProviderAccount, CLIActivitySnapshot)

  var id: String {
    switch self {
    case .addClaudeAccount: "add-claude-account"
    case let .switchBlocked(account, _): "switch-blocked-\(account.id)"
    }
  }

  var title: String {
    switch self {
    case .addClaudeAccount: "Keep running Claude Code sessions?"
    case .switchBlocked: "Quit Claude Code before switching"
    }
  }

  var confirmButtonTitle: String {
    switch self {
    case .addClaudeAccount: "Continue Login"
    case .switchBlocked: "Try Again"
    }
  }

  var message: String {
    switch self {
    case let .addClaudeAccount(activitySnapshot):
      CLIActivityWarningPresentation.message(for: activitySnapshot)
    case let .switchBlocked(_, activitySnapshot):
      CLIActivityWarningPresentation.switchBlockedMessage(for: activitySnapshot)
    }
  }

  var dismissesBeforeConfirming: Bool {
    switch self {
    case .addClaudeAccount: true
    case .switchBlocked: false
    }
  }
}
