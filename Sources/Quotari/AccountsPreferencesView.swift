import QuotariCore
import SwiftUI

struct AccountsPreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var confirmation: AccountManagementConfirmation?

  var body: some View {
    @Bindable var store = store

    Form {
      Section("Providers") {
        ForEach(store.providers, id: \.id) { descriptor in
          VStack(alignment: .leading, spacing: 2) {
            Toggle(
              descriptor.metadata.displayName,
              isOn: $store[providerEnabled: descriptor.id]
            )
            if store.credentialDiscoveryState(for: descriptor.id) == .absent {
              Text("No credentials detected. When enabled, Quotari may show demo data until an account is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        Text("These switches control providers across Quotari. Quota alerts are configured separately.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Accounts") {
        ForEach(store.providers, id: \.id) { descriptor in
          VStack(alignment: .leading, spacing: 6) {
            let canAddAccount = store.canAddAccount(for: descriptor.id)
            HStack {
              accountPicker(
                for: descriptor,
                selection: $store[selectedAccountID: descriptor.id]
              )
              Button {
                store.startAddingAccount(for: descriptor.id)
              } label: {
                if store.addingAccountProviders.contains(descriptor.id) {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Label(accountLoginTitle(for: descriptor.id), systemImage: "plus")
                }
              }
              .disabled(!store.addingAccountProviders.isEmpty || !canAddAccount)
              .help(store.addAccountUnavailableReason(for: descriptor.id) ?? accountLoginHelp(for: descriptor.id))
            }
            monitoringSelection(for: descriptor)
            if descriptor.id == .claude {
              Text(
                "Claude keeps one shared CLI login. Quotari saves the current account before browser login, "
                  + "then adds the new account automatically."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = store.addAccountUnavailableReason(for: descriptor.id) {
              Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            AccountLoginStatusView(provider: descriptor.id)
            if let error = store.captureErrors[descriptor.id] {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Button("Scan & Add Current Accounts") { Task { await scanAccountsButtonTapped() } }
      }
    }
    .formStyle(.grouped)
    .alert(item: $confirmation) { confirmation in
      switch confirmation {
      case let .switchCLI(account):
        Alert(
          title: Text("Switch CLI account?"),
          message: Text(
            "Quit active Claude Code or Codex sessions first. Quotari will preserve the current login, then put "
              + "\(store.accountLabel(for: account)) into the shared CLI slot."
          ),
          primaryButton: .default(Text("Switch Account")) {
            Task { await store.switchCLIAccount(to: account) }
          },
          secondaryButton: .cancel()
        )
      case let .remove(account):
        Alert(
          title: Text("Remove saved account?"),
          message: Text(
            "This removes \(store.accountLabel(for: account)) from Quotari. The provider account remains intact."
          ),
          primaryButton: .destructive(Text("Remove")) {
            Task { await store.removeCapturedAccount(account) }
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  private func accountPicker(
    for descriptor: ProviderDescriptor,
    selection: Binding<String>
  ) -> some View {
    let provider = descriptor.id
    let accounts = displayedAccounts(for: provider)

    return Picker("\(descriptor.metadata.displayName) Dashboard", selection: selection) {
      Text("Automatic")
        .tag("")
      ForEach(accounts) { account in
        Text(accountLabel(account))
          .tag(account.id)
      }
    }
    .frame(maxWidth: .infinity)
    .disabled(accounts.isEmpty)
  }

  private func monitoringSelection(for descriptor: ProviderDescriptor) -> some View {
    let accounts = displayedAccounts(for: descriptor.id)
    let activeCLIID = store.activeCLIAccount(for: descriptor.id)?.id
    return VStack(alignment: .leading, spacing: 4) {
      Text("Monitored Accounts")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      if accounts.isEmpty {
        Text("No accounts available")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(accounts) { account in
          HStack(spacing: 8) {
            Toggle(isOn: monitoringBinding(for: account)) {
              HStack(spacing: 6) {
                Text(accountLabel(account))
                  .lineLimit(1)
                if account.id == activeCLIID {
                  Text("CLI Active")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
              }
            }
            .toggleStyle(.checkbox)
            if account.credentialSource.isCaptured {
              Button("Switch") {
                confirmation = .switchCLI(account)
              }
              .controlSize(.small)
              .disabled(store.isSwitching || !store.addingAccountProviders.isEmpty)
              Button {
                confirmation = .remove(account)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help("Remove saved account")
              .disabled(store.isSwitching || !store.addingAccountProviders.isEmpty)
            }
          }
        }
      }
      Text(
        "Checked accounts refresh in the background. The dashboard account and CLI active account remain single choices."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func monitoringBinding(for account: ProviderAccount) -> Binding<Bool> {
    Binding(
      get: { store.isMonitoring(account) },
      set: { isMonitored in
        store.setMonitoring(isMonitored, for: account)
        guard isMonitored else { return }
        Task { await store.refreshAccountUsage(for: account) }
      }
    )
  }

  private func displayedAccounts(for provider: UsageProvider) -> [ProviderAccount] {
    var accounts = store.accounts[provider] ?? []
    if let selected = store.selectedAccounts[provider],
       !accounts.contains(where: { $0.id == selected.id }) {
      accounts.append(selected)
    }
    return accounts
  }

  private func scanAccountsButtonTapped() async {
    await store.reloadAccounts()
  }

  private func accountLabel(_ account: ProviderAccount) -> String {
    let name = store.accountLabel(for: account)
    guard let detail = account.detail, !detail.isEmpty else {
      return name
    }
    return "\(name) (\(detail))"
  }

  private func accountLoginTitle(for provider: UsageProvider) -> String {
    provider == .claude ? "Login New Account" : "Add Account"
  }

  private func accountLoginHelp(for provider: UsageProvider) -> String {
    provider == .claude
      ? "Preserve the current Claude account, then sign in with a new one in the browser"
      : "Add another managed account"
  }
}

private enum AccountManagementConfirmation: Identifiable {
  case switchCLI(ProviderAccount)
  case remove(ProviderAccount)

  var id: String {
    switch self {
    case let .switchCLI(account): "switch-\(account.id)"
    case let .remove(account): "remove-\(account.id)"
    }
  }
}
