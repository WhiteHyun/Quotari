import QuotariCore
import SwiftUI

struct AccountsPreferencesView: View {
  @Environment(UsageStore.self) private var store

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
                Task { await store.addAccount(for: descriptor.id) }
              } label: {
                if store.addingAccountProviders.contains(descriptor.id) {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Label("Add Account", systemImage: "plus")
                }
              }
              .disabled(!store.addingAccountProviders.isEmpty || !canAddAccount)
              .help(store.addAccountUnavailableReason(for: descriptor.id) ?? "Add another managed account")
            }
            monitoringSelection(for: descriptor)
            if let reason = store.addAccountUnavailableReason(for: descriptor.id) {
              Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.accountLoginErrors[descriptor.id] {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let output = store.accountLoginOutputs[descriptor.id], !output.isEmpty {
              Text(output)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Button("Scan Accounts") { Task { await scanAccountsButtonTapped() } }
      }
    }
    .formStyle(.grouped)
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
        Task { await store.refreshAccountUsage(for: account.provider, force: true) }
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
}
