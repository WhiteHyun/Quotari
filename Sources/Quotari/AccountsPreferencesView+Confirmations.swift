import QuotariCore
import SwiftUI

extension AccountsPreferencesView {
  func confirmationAlert(for confirmation: AccountManagementConfirmation) -> Alert {
    switch confirmation {
    case let .addClaudeAccount(activitySnapshot):
      addClaudeAccountAlert(activitySnapshot)
    case let .switchCLI(account):
      switchCLIAlert(account)
    case let .remove(account):
      removeAccountAlert(account)
    }
  }

  func accountLoginButtonTapped(for provider: UsageProvider) {
    guard provider == .claude else {
      store.startAddingAccount(for: provider)
      return
    }
    guard cliActivityInspection.begin() else { return }
    Task {
      defer { cliActivityInspection.finish() }
      do {
        let activitySnapshot = try await store.cliActivitySnapshot(for: provider)
        if activitySnapshot.isActive {
          confirmation = .addClaudeAccount(activitySnapshot)
        } else {
          store.startAddingAccount(for: provider)
        }
      } catch {
        store.accountLoginErrors[provider] = AccountLoginError.cliActivityCheckFailed(
          provider,
          underlying: error.localizedDescription
        ).localizedDescription
      }
    }
  }

  func switchButtonTapped(_ account: ProviderAccount) {
    guard account.provider == .claude else {
      confirmation = .switchCLI(account)
      return
    }
    guard cliActivityInspection.begin() else { return }
    Task {
      defer { cliActivityInspection.finish() }
      do {
        let activitySnapshot = try await store.cliActivitySnapshot(for: account.provider)
        if activitySnapshot.isActive {
          store.captureErrors[account.provider] = AccountSwitchError.cliStillRunning(
            processes: activitySnapshot.processes
          ).localizedDescription
        } else {
          confirmation = .switchCLI(account)
        }
      } catch {
        store.captureErrors[account.provider] = AccountSwitchError.cliActivityCheckFailed(
          underlying: error.localizedDescription
        ).localizedDescription
      }
    }
  }

  private func addClaudeAccountAlert(_ activitySnapshot: CLIActivitySnapshot) -> Alert {
    Alert(
      title: Text(L10n.string("Keep running Claude Code sessions?")),
      message: Text(CLIActivityWarningPresentation.message(for: activitySnapshot)),
      primaryButton: .default(Text(L10n.string("Continue Login"))) {
        store.startAddingAccount(
          for: .claude,
          allowingActiveSessions: activitySnapshot
        )
      },
      secondaryButton: .cancel()
    )
  }

  private func switchCLIAlert(_ account: ProviderAccount) -> Alert {
    Alert(
      title: Text(L10n.string("Switch CLI account?")),
      message: Text(switchConfirmationMessage(for: account)),
      primaryButton: .default(Text(L10n.string("Switch Account"))) {
        Task {
          await store.switchCLIAccount(to: account)
        }
      },
      secondaryButton: .cancel()
    )
  }

  private func removeAccountAlert(_ account: ProviderAccount) -> Alert {
    Alert(
      title: Text(L10n.string("Remove saved account?")),
      message: Text(
        L10n.string(
          "This removes \(store.accountLabel(for: account)) from Quotari. The provider account remains intact."
        )
      ),
      primaryButton: .destructive(Text(L10n.string("Remove"))) {
        Task { await store.removeCapturedAccount(account) }
      },
      secondaryButton: .cancel()
    )
  }

  private func switchConfirmationMessage(for account: ProviderAccount) -> String {
    let key = account.provider == .claude
      ? "Quotari will preserve the current login, then put %@ into the shared CLI slot."
      : "Quit active Claude Code or Codex sessions first. Quotari will preserve the current login, "
      + "then put %@ into the shared CLI slot."
    return String.localizedStringWithFormat(
      L10n.string(key: key),
      store.accountLabel(for: account)
    )
  }
}

enum AccountManagementConfirmation: Identifiable {
  case addClaudeAccount(CLIActivitySnapshot)
  case switchCLI(ProviderAccount)
  case remove(ProviderAccount)

  var id: String {
    switch self {
    case .addClaudeAccount: "add-claude-account"
    case let .switchCLI(account): "switch-\(account.id)"
    case let .remove(account): "remove-\(account.id)"
    }
  }
}
