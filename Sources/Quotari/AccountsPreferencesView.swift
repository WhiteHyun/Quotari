import QuotariCore
import SwiftUI

struct AccountsPreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var confirmation: AccountManagementConfirmation?

  var body: some View {
    VStack(spacing: 16) {
      providersCard
      accountsCard
    }
    .alert(item: $confirmation) { confirmationAlert(for: $0) }
  }

  private var providersCard: some View {
    @Bindable var store = store
    return PreferencesCard(
      L10n.string("Providers"),
      subtitle: L10n.string("Choose the AI services that appear throughout Quotari.")
    ) {
      VStack(spacing: 14) {
        ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, descriptor in
          providerToggleRow(descriptor, isEnabled: $store[providerEnabled: descriptor.id])
          if index < store.providers.count - 1 {
            PreferencesRowDivider()
          }
        }
      }
    }
  }

  private var accountsCard: some View {
    PreferencesCard(
      L10n.string("Accounts"),
      subtitle: L10n.string("Monitor usage across accounts and switch the shared CLI login.")
    ) {
      VStack(spacing: 20) {
        ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, descriptor in
          providerAccountSection(descriptor)
          if index < store.providers.count - 1 {
            PreferencesRowDivider()
          }
        }
        HStack {
          Spacer()
          Button(L10n.string("Scan & Add Current Accounts")) {
            Task { await scanAccountsButtonTapped() }
          }
          .buttonStyle(.borderedProminent)
          .tint(Theme.brandAccent)
        }
      }
    }
  }

  private func confirmationAlert(for confirmation: AccountManagementConfirmation) -> Alert {
    switch confirmation {
    case let .switchCLI(account):
      Alert(
        title: Text(L10n.string("Switch CLI account?")),
        message: Text(
          L10n.string(
            """
            Quit active Claude Code or Codex sessions first. Quotari will preserve the current login, then put \
            \(store.accountLabel(for: account)) into the shared CLI slot.
            """
          )
        ),
        primaryButton: .default(Text(L10n.string("Switch Account"))) {
          Task { await store.switchCLIAccount(to: account) }
        },
        secondaryButton: .cancel()
      )
    case let .remove(account):
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
  }
}

private extension AccountsPreferencesView {
  private func providerToggleRow(
    _ descriptor: ProviderDescriptor,
    isEnabled: Binding<Bool>
  ) -> some View {
    HStack(spacing: 13) {
      ProviderIconView(descriptor: descriptor)
      VStack(alignment: .leading, spacing: 2) {
        Text(descriptor.metadata.displayName)
          .font(.body.weight(.medium))
        HStack(spacing: 5) {
          Circle()
            .fill(providerStatusColor(for: descriptor.id))
            .frame(width: 7, height: 7)
          Text(providerStatusTitle(for: descriptor.id))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Toggle(descriptor.metadata.displayName, isOn: isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(.blue)
    }
  }

  private func providerAccountSection(_ descriptor: ProviderDescriptor) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      providerAccountHeader(descriptor)
      accountList(for: descriptor)
      providerAccountGuidance(descriptor)
      AccountLoginStatusView(provider: descriptor.id)
      if let error = store.captureErrors[descriptor.id] {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func providerAccountHeader(_ descriptor: ProviderDescriptor) -> some View {
    let canAddAccount = store.canAddAccount(for: descriptor.id)
    return HStack(spacing: 12) {
      ProviderIconView(descriptor: descriptor, size: 34)
      Text(descriptor.metadata.displayName)
        .font(.headline)
      Spacer()
      accountPicker(
        for: descriptor,
        selection: Binding(
          get: { store[selectedAccountID: descriptor.id] },
          set: { store[selectedAccountID: descriptor.id] = $0 }
        )
      )
      Button {
        store.startAddingAccount(for: descriptor.id)
      } label: {
        Group {
          if store.addingAccountProviders.contains(descriptor.id) {
            ProgressView()
              .controlSize(.small)
          } else {
            Label(accountLoginTitle(for: descriptor.id), systemImage: "plus")
          }
        }
        .frame(width: 150)
      }
      .disabled(!store.addingAccountProviders.isEmpty || !canAddAccount)
      .help(store.addAccountUnavailableReason(for: descriptor.id) ?? accountLoginHelp(for: descriptor.id))
    }
  }

  @ViewBuilder
  private func providerAccountGuidance(_ descriptor: ProviderDescriptor) -> some View {
    if descriptor.id == .claude {
      Text(
        L10n.string(
          """
          Claude keeps one shared CLI login. Quotari saves the current account before browser login, \
          then adds the new account automatically.
          """
        )
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
  }

  private func accountPicker(
    for descriptor: ProviderDescriptor,
    selection: Binding<String>
  ) -> some View {
    let provider = descriptor.id
    let accounts = displayedAccounts(for: provider)

    return Picker(L10n.string("\(descriptor.metadata.displayName) Dashboard"), selection: selection) {
      Text(L10n.string("Automatic"))
        .tag("")
      ForEach(accounts) { account in
        Text(accountLabel(account))
          .tag(account.id)
      }
    }
    .labelsHidden()
    .frame(width: 190)
    .disabled(accounts.isEmpty)
    .accessibilityLabel(L10n.string("\(descriptor.metadata.displayName) dashboard account"))
  }
}

private extension AccountsPreferencesView {
  private func accountList(for descriptor: ProviderDescriptor) -> some View {
    let accounts = displayedAccounts(for: descriptor.id)
    let activeCLIID = store.activeCLIAccount(for: descriptor.id)?.id
    return VStack(alignment: .leading, spacing: 4) {
      Text(L10n.string("Accounts"))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      if accounts.isEmpty {
        Text(L10n.string("No accounts available"))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(accounts) { account in
          accountRow(account, activeCLIID: activeCLIID)
        }
      }
      accountListFooter
    }
  }

  private func accountRow(_ account: ProviderAccount, activeCLIID: String?) -> some View {
    let label = store.accountLabel(for: account)
    return HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 7) {
          Text(label)
            .lineLimit(1)
          if account.id == activeCLIID {
            PreferencesBadge(title: L10n.string("CLI Active"), color: .blue)
          }
          if account.credentialSource.isCaptured {
            PreferencesBadge(title: L10n.string("Saved"), color: Theme.brandAccent)
          }
        }
        if let detail = account.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 12)
      if account.credentialSource.isCaptured {
        savedAccountActions(account)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func savedAccountActions(_ account: ProviderAccount) -> some View {
    Group {
      Button(L10n.string("Switch")) {
        confirmation = .switchCLI(account)
      }
      .controlSize(.small)
      Button {
        confirmation = .remove(account)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help(L10n.string("Remove saved account"))
    }
    .disabled(store.isSwitching || !store.addingAccountProviders.isEmpty)
  }

  private var accountListFooter: some View {
    Text(
      L10n.string(
        "All accounts refresh in the background. The dashboard account and CLI active account remain single choices."
      )
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func providerStatusTitle(for provider: UsageProvider) -> String {
    switch store.credentialDiscoveryState(for: provider) {
    case .unknown: L10n.string("Checking credentials…")
    case .present: L10n.string("Connected")
    case .absent: L10n.string("No credentials detected")
    }
  }

  private func providerStatusColor(for provider: UsageProvider) -> Color {
    switch store.credentialDiscoveryState(for: provider) {
    case .unknown: .secondary
    case .present: .green
    case .absent: .orange
    }
  }
}

private extension AccountsPreferencesView {
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
    provider == .claude ? L10n.string("Login New Account") : L10n.string("Add Account")
  }

  private func accountLoginHelp(for provider: UsageProvider) -> String {
    provider == .claude
      ? L10n.string("Preserve the current Claude account, then sign in with a new one in the browser")
      : L10n.string("Add another managed account")
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
