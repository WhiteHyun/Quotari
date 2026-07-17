import QuotariCore
import SwiftUI

struct ProviderAccountPopover: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  let descriptor: ProviderDescriptor

  @State private var isReloadingAccounts = false
  @State private var switchCoordinator = ProviderAccountPopoverSwitchCoordinator()

  private var accent: Color {
    Color(
      red: descriptor.metadata.accent.r,
      green: descriptor.metadata.accent.g,
      blue: descriptor.metadata.accent.b
    )
  }

  private var accounts: [ProviderAccount] {
    store.accounts[descriptor.id] ?? []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      VStack(spacing: 8) {
        ForEach(accounts) { account in
          accountButton(account)
        }
      }
      if let error = store.captureErrors[descriptor.id] {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      AccountLoginStatusView(provider: descriptor.id)
      Divider()
      footer
    }
    .padding(12)
    .frame(width: 330)
    .task {
      await store.refreshAccountUsage(for: descriptor.id)
    }
  }

  private var header: some View {
    let monitoredCount = accounts.filter(store.isMonitoring).count
    return HStack(alignment: .firstTextBaseline) {
      Text("\(descriptor.metadata.displayName) Accounts")
        .font(.headline)
      Spacer()
      Text("\(monitoredCount)/\(accounts.count) monitored")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func accountButton(_ account: ProviderAccount) -> some View {
    let isSelected = store.activeAccount(for: descriptor.id)?.id == account.id
    let isCLIActive = store.activeCLIAccount(for: descriptor.id)?.id == account.id
    let isMonitored = store.isMonitoring(account)
    let usage = store.accountUsage(for: account)
    let action = ProviderAccountPopoverAction(account: account, isCLIActive: isCLIActive)
    return Button {
      perform(action, for: account)
    } label: {
      ProviderAccountUsageRow(
        account: account,
        label: store.accountLabel(for: account),
        usage: usage,
        isSelected: isSelected,
        isCLIActive: isCLIActive,
        isMonitored: isMonitored,
        isLoading: isMonitored && store.refreshingAccountUsageProviders.contains(descriptor.id) && usage == nil,
        isSwitching: switchCoordinator.switchingAccountID == account.id,
        accent: accent
      )
    }
    .buttonStyle(.plain)
    .disabled(store.isSwitching || !store.addingAccountProviders.isEmpty)
    .accessibilityHint(action.accessibilityHint)
    .help(action.accessibilityHint)
    .contextMenu { accountMenu(account) }
  }

  private func perform(_ action: ProviderAccountPopoverAction, for account: ProviderAccount) {
    switch action {
    case .selectDashboard:
      store.selectAccount(account, for: descriptor.id)
      dismiss()
    case .switchCLI:
      startSwitchingCLI(to: account)
    }
  }

  private func startSwitchingCLI(to account: ProviderAccount) {
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

  @ViewBuilder
  private func accountMenu(_ account: ProviderAccount) -> some View {
    Button(store.isMonitoring(account) ? "Stop Monitoring" : "Monitor Account") {
      let shouldMonitor = !store.isMonitoring(account)
      store.setMonitoring(shouldMonitor, for: account)
      if shouldMonitor {
        Task { await store.refreshAccountUsage(for: account) }
      }
    }
    if store.capturedEquivalents.keys.contains(account.id) {
      Button("Remove Account (Still in CLI)", role: .destructive) {}
        .disabled(true)
        .help(UsageStore.activeAccountRemovalMessage)
    }
    if account.credentialSource.isCaptured {
      Button("Use in CLI (Switch)") {
        startSwitchingCLI(to: account)
      }
      .disabled(store.isSwitching || !store.addingAccountProviders.isEmpty)
      Button("Remove Account", role: .destructive) {
        Task { await store.removeCapturedAccount(account) }
      }
    }
  }

  private var footer: some View {
    let canAddAccount = store.canAddAccount(for: descriptor.id)
    return VStack(spacing: 2) {
      PopoverActionButton(
        title: canAddAccount ? accountLoginTitle : "\(accountLoginTitle) (Unavailable)",
        systemImage: "plus",
        busy: !store.addingAccountProviders.isEmpty,
        disabled: !canAddAccount
      ) {
        store.startAddingAccount(for: descriptor.id)
      }
      .help(store.addAccountUnavailableReason(for: descriptor.id) ?? accountLoginHelp)
      PopoverActionButton(
        title: "Scan & Add Current Account",
        systemImage: "arrow.clockwise",
        busy: isReloadingAccounts || store.refreshingAccountUsageProviders.contains(descriptor.id)
      ) {
        Task {
          isReloadingAccounts = true
          defer { isReloadingAccounts = false }
          await store.reloadAccounts()
          await store.refreshAccountUsage(
            for: descriptor.id,
            force: true,
            interaction: .userInitiated
          )
        }
      }
      PopoverActionButton(
        title: "Manage in Settings…",
        systemImage: "gearshape",
        busy: false
      ) {
        SettingsWindowController.shared.show(store: store)
      }
    }
  }

  private var accountLoginTitle: String {
    descriptor.id == .claude ? "Login New Account" : "Add Account"
  }

  private var accountLoginHelp: String {
    descriptor.id == .claude
      ? "Preserve the current Claude account, then sign in with a new one in the browser"
      : "Add another managed account"
  }
}

private struct ProviderAccountUsageRow: View {
  let account: ProviderAccount
  let label: String
  let usage: ProviderAccountUsage?
  let isSelected: Bool
  let isCLIActive: Bool
  let isMonitored: Bool
  let isLoading: Bool
  let isSwitching: Bool
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        if isSwitching {
          ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? accent : Color.secondary)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(label)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          if let detail = account.detail {
            Text(detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
        if isCLIActive {
          accountBadge("CLI Active", color: .secondary)
        }
        if isMonitored {
          accountBadge("Monitored", color: accent)
        }
        if account.credentialSource.isCaptured {
          accountBadge("Saved", color: accent)
        }
        if let plan = usage?.snapshot?.plan {
          Text(plan)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      usageContent
        .padding(.leading, 28)
    }
    .padding(10)
    .contentShape(Rectangle())
    .background(
      isSelected ? accent.opacity(0.08) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isSelected ? accent.opacity(0.75) : Color.primary.opacity(0.1))
    }
  }

  private func accountBadge(_ title: String, color: Color) -> some View {
    Text(title)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  @ViewBuilder
  private var usageContent: some View {
    if let snapshot = usage?.snapshot {
      VStack(spacing: 9) {
        if let primary = snapshot.primary {
          compactWindow("Session", primary)
        }
        if let secondary = snapshot.secondary {
          compactWindow("Weekly", secondary)
        }
        if snapshot.primary == nil, snapshot.secondary == nil {
          Text("No usage windows available")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    } else if let error = usage?.error {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      HStack(spacing: 6) {
        if isLoading {
          ProgressView().controlSize(.small)
        }
        Text(isLoading ? "Loading usage…" : "Usage not loaded")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func compactWindow(_ title: String, _ window: RateWindow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.medium))
      AccountUsageBar(remainingPercent: window.remainingPercent, accent: accent)
      HStack(spacing: 6) {
        Text("\(UsageFormatter.percent(window.remainingPercent)) left")
        Spacer()
        if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
          Text("Resets \(reset)")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct AccountUsageBar: View {
  let remainingPercent: Double
  let accent: Color

  var body: some View {
    GeometryReader { proxy in
      let fraction = min(1, max(0, remainingPercent / 100))
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.usageTrack)
        Capsule()
          .fill(accent)
          .frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * fraction))
      }
    }
    .frame(height: 4)
  }
}

private struct PopoverActionButton: View {
  let title: String
  let systemImage: String
  let busy: Bool
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if busy {
        PopoverActionLabel(title: title, systemImage: nil, busy: true)
      } else {
        PopoverActionLabel(title: title, systemImage: systemImage)
      }
    }
    .buttonStyle(.plain)
    .disabled(busy || disabled)
  }
}

struct PopoverActionLabel: View {
  let title: String
  let systemImage: String?
  var busy = false

  var body: some View {
    HStack(spacing: 8) {
      if busy {
        ProgressView()
          .controlSize(.small)
          .frame(width: 16, height: 16)
      } else if let systemImage {
        Image(systemName: systemImage)
          .frame(width: 16)
      }
      Text(title)
      Spacer()
    }
    .font(.body)
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
  }
}
