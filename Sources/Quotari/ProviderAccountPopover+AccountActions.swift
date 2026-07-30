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
    Task {
      do {
        let activitySnapshot = try await store.cliActivitySnapshot(for: account.provider)
        if activitySnapshot.isActive {
          confirmation = .switchCLI(account, activitySnapshot: activitySnapshot)
        } else {
          startSwitchingCLI(to: account)
        }
      } catch {
        store.captureErrors[account.provider] = AccountSwitchError.cliActivityCheckFailed(
          underlying: error.localizedDescription
        ).localizedDescription
      }
    }
  }

  func startSwitchingCLI(
    to account: ProviderAccount,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot? = nil
  ) {
    Task {
      let shouldDismiss = await switchCoordinator.switchCLI(to: account) {
        await store.switchCLIAccount(
          to: account,
          allowingActiveSessions: activitySnapshot
        )
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
    Task {
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

  func confirmationAlert(for confirmation: ProviderAccountPopoverConfirmation) -> Alert {
    let activitySnapshot = confirmation.activitySnapshot
    let buttonTitle = switch confirmation {
    case .addClaudeAccount: L10n.string("Continue Login")
    case .switchCLI: L10n.string("Continue Switch")
    }
    return Alert(
      title: Text(L10n.string("Keep running Claude Code sessions?")),
      message: Text(CLIActivityWarningPresentation.message(for: activitySnapshot)),
      primaryButton: .default(Text(buttonTitle)) {
        performConfirmedOperation(confirmation)
      },
      secondaryButton: .cancel()
    )
  }

  private func performConfirmedOperation(_ confirmation: ProviderAccountPopoverConfirmation) {
    switch confirmation {
    case let .addClaudeAccount(activitySnapshot):
      store.startAddingAccount(
        for: .claude,
        allowingActiveSessions: activitySnapshot
      )
    case let .switchCLI(account, activitySnapshot):
      startSwitchingCLI(
        to: account,
        allowingActiveSessions: activitySnapshot
      )
    }
  }
}

enum ProviderAccountPopoverConfirmation: Identifiable {
  case addClaudeAccount(CLIActivitySnapshot)
  case switchCLI(ProviderAccount, activitySnapshot: CLIActivitySnapshot)

  var id: String {
    switch self {
    case .addClaudeAccount: "add-claude-account"
    case let .switchCLI(account, _): "switch-\(account.id)"
    }
  }

  var activitySnapshot: CLIActivitySnapshot {
    switch self {
    case let .addClaudeAccount(activitySnapshot), let .switchCLI(_, activitySnapshot):
      activitySnapshot
    }
  }
}
