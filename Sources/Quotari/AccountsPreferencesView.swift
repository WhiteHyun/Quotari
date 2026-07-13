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
          accountPicker(
            for: descriptor,
            selection: $store[selectedAccountID: descriptor.id]
          )
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
    var accounts = store.accounts[provider] ?? []
    if let selected = store.selectedAccounts[provider],
       !accounts.contains(where: { $0.id == selected.id }) {
      accounts.append(selected)
    }

    return Picker(descriptor.metadata.displayName, selection: selection) {
      Text("Automatic")
        .tag("")
      ForEach(accounts) { account in
        Text(accountLabel(account))
          .tag(account.id)
      }
    }
    .disabled(accounts.isEmpty)
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
