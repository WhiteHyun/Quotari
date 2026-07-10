import QuotariCore
import SwiftUI

struct PreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var intervalMinutes: Double = 1

  var body: some View {
    Form {
      Section("Menu Bar") {
        Picker("Icon", selection: Binding(
          get: { store.iconStyle },
          set: { store.iconStyle = $0 }
        )) {
          ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
            Text(style.label)
              .tag(style)
          }
        }
      }
      Section("Refresh") {
        Slider(value: $intervalMinutes, in: 1 ... 30, step: 1) {
          Text("Interval")
        } minimumValueLabel: {
          Text("1m")
        } maximumValueLabel: {
          Text("30m")
        }
        Text("Every \(Int(intervalMinutes)) minute(s)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Accounts") {
        ForEach(store.providers, id: \.id) { descriptor in
          accountPicker(for: descriptor)
        }
        Button("Scan Accounts") {
          Task { await store.reloadAccounts() }
        }
      }
      Section("About") {
        LabeledContent("App", value: "Quotari")
        LabeledContent("Providers", value: "\(store.providers.count)")
        LabeledContent("Updates") {
          Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
            .disabled(!UpdaterController.shared.isAvailable)
        }
        if !UpdaterController.shared.isAvailable {
          Text("Automatic updates are available in packaged releases.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 430)
    .onAppear { intervalMinutes = store.refreshInterval / 60 }
    .onChange(of: intervalMinutes) { _, newValue in
      store.refreshInterval = newValue * 60
    }
  }

  private func accountPicker(for descriptor: ProviderDescriptor) -> some View {
    let provider = descriptor.id
    var accounts = store.accounts[provider] ?? []
    if let selected = store.selectedAccounts[provider],
       !accounts.contains(where: { $0.id == selected.id }) {
      accounts.append(selected)
    }
    let selection = Binding<String>(
      get: { store.selectedAccounts[provider]?.id ?? "" },
      set: { store.selectAccount(id: $0.isEmpty ? nil : $0, for: provider) }
    )

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

  private func accountLabel(_ account: ProviderAccount) -> String {
    guard let detail = account.detail, !detail.isEmpty else {
      return account.displayName
    }
    return "\(account.displayName) (\(detail))"
  }
}
