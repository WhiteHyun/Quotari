import QuotariCore
import SwiftUI

struct ProviderAccountPopover: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  let descriptor: ProviderDescriptor

  @State private var isReloadingAccounts = false

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

  private var activeAccount: ProviderAccount? {
    store.activeAccount(for: descriptor.id)
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
    HStack(alignment: .firstTextBaseline) {
      Text("\(descriptor.metadata.displayName) Accounts")
        .font(.headline)
      Spacer()
      Text("\(accounts.count) \(accounts.count == 1 ? "account" : "accounts")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func accountButton(_ account: ProviderAccount) -> some View {
    let isSelected = store.activeAccount(for: descriptor.id)?.id == account.id
    let usage = store.accountUsage(for: account)
    return Button {
      store.selectAccount(account, for: descriptor.id)
      dismiss()
    } label: {
      ProviderAccountUsageRow(
        account: account,
        usage: usage,
        isSelected: isSelected,
        isLoading: store.refreshingAccountUsageProviders.contains(descriptor.id) && usage == nil,
        accent: accent
      )
    }
    .buttonStyle(.plain)
    .accessibilityHint("Selects this account and updates the dashboard")
    .contextMenu { accountMenu(account) }
  }

  @ViewBuilder
  private func accountMenu(_ account: ProviderAccount) -> some View {
    if store.isCapturable(account) {
      Button("Save to Quotari") {
        Task { await store.captureAccount(account) }
      }
    }
    if store.capturedEquivalentIDs.contains(account.id) {
      // The saved copy's own row is hidden while this login is live, so the
      // live row is the only place its removal can be offered.
      Button("Remove Saved Copy", role: .destructive) {
        Task { await store.removeCapturedCopy(of: account) }
      }
    }
    if account.credentialSource.isCaptured {
      Button("Remove Saved Account", role: .destructive) {
        Task { await store.removeCapturedAccount(account) }
      }
    }
  }

  private var footer: some View {
    VStack(spacing: 2) {
      if let active = activeAccount, store.isCapturable(active) {
        PopoverActionButton(
          title: "Save “\(active.displayName)” to Quotari",
          systemImage: "square.and.arrow.down",
          busy: false
        ) {
          Task { await store.captureAccount(active) }
        }
      }
      PopoverActionButton(
        title: "Reload Accounts",
        systemImage: "arrow.clockwise",
        busy: isReloadingAccounts || store.refreshingAccountUsageProviders.contains(descriptor.id)
      ) {
        Task {
          isReloadingAccounts = true
          defer { isReloadingAccounts = false }
          await store.reloadAccounts()
          await store.refreshAccountUsage(for: descriptor.id, force: true)
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
}

private struct ProviderAccountUsageRow: View {
  let account: ProviderAccount
  let usage: ProviderAccountUsage?
  let isSelected: Bool
  let isLoading: Bool
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? accent : Color.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(account.displayName)
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
        if account.credentialSource.isCaptured {
          Text("Saved")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accent.opacity(0.15), in: Capsule())
            .foregroundStyle(accent)
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
    .disabled(busy)
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
