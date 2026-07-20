import QuotariCore
import SwiftUI

struct ProviderCardView: View {
  @Environment(UsageStore.self) private var store

  let descriptor: ProviderDescriptor
  let snapshot: UsageSnapshot?
  let sourceLabel: String?
  let error: String?
  var showSettings: () -> Void = {}

  @State private var isShowingAccounts = false

  private var accent: Color {
    Color(
      red: descriptor.metadata.accent.r,
      green: descriptor.metadata.accent.g,
      blue: descriptor.metadata.accent.b
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if let snapshot {
        if let primary = snapshot.primary {
          windowRow("Session", primary)
        }
        if let secondary = snapshot.secondary {
          windowRow("Weekly", secondary)
        }
        ForEach(snapshot.extraWindows) { named in windowRow(named.title, named.window) }
        if let cost = snapshot.cost {
          Divider().padding(.vertical, 2)
          CostSectionView(cost: cost, accent: accent)
        }
      } else if let error {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .lineLimit(2)
      } else {
        Text("Loading…")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  private var header: some View {
    VStack(spacing: 2) {
      HStack(alignment: .top, spacing: 8) {
        ProviderIconView(descriptor: descriptor, size: 24)
        Text(descriptor.metadata.displayName).font(.headline)
        Spacer()
        accountControl
      }
      HStack {
        if let snapshot {
          ProviderFreshnessView(
            updatedAt: snapshot.updatedAt,
            refreshInterval: store.refreshInterval,
            sourceLabel: sourceLabel
          )
        } else if let sourceLabel {
          Text(sourceLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
  }

  @ViewBuilder
  private var accountControl: some View {
    if !providerAccounts.isEmpty {
      Button {
        isShowingAccounts.toggle()
      } label: {
        HStack(spacing: 6) {
          accountLabels
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
          isShowingAccounts ? Color.primary.opacity(0.07) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
      }
      .buttonStyle(.plain)
      .popover(
        isPresented: $isShowingAccounts,
        attachmentAnchor: .rect(.bounds),
        arrowEdge: .leading
      ) {
        ProviderAccountPopover(
          descriptor: descriptor,
          showSettings: showSettings
        )
        .environment(store)
      }
      .accessibilityLabel("\(descriptor.metadata.displayName) account")
      .accessibilityHint("Shows usage for available accounts")
    } else if accountDisplayName != nil || snapshot?.plan != nil {
      accountLabels
    }
  }

  private var accountLabels: some View {
    VStack(alignment: .trailing, spacing: 1) {
      if let accountDisplayName {
        Text(accountDisplayName)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      if let plan = snapshot?.plan {
        Text(plan)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: 180, alignment: .trailing)
  }

  private var providerAccounts: [ProviderAccount] {
    store.accounts[descriptor.id] ?? []
  }

  private var accountDisplayName: String? {
    // Use the account's label (a fetched Claude email when available) rather
    // than its raw display name, so the card doesn't regress to the generic
    // "Claude Code" once the profile cache populates and activeAccount starts
    // resolving. Fall back to the snapshot's own account name.
    if let active = store.activeAccount(for: descriptor.id) {
      return store.accountLabel(for: active)
    }
    return snapshot?.account
  }

  @ViewBuilder
  private func windowRow(_ title: String, _ window: RateWindow) -> some View {
    let pace = UsagePace.compute(window: window, now: Date())
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.subheadline)
      bar(window.remainingPercent)
      HStack(spacing: 6) {
        Text("\(UsageFormatter.percent(window.remainingPercent)) left")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
        Spacer()
        if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
          Text("Resets \(reset)").font(.footnote).foregroundStyle(.secondary)
        }
      }
      if window.usedPercent < 100, let pace,
         UsageFormatter.paceTrend(pace) != nil || pace.runsOutIn != nil {
        HStack(spacing: 6) {
          if let trend = UsageFormatter.paceTrend(pace) {
            Text(trend)
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          Spacer()
          Text(UsageFormatter.paceProjection(pace))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title) usage")
    .accessibilityValue(accessibilityValue(for: window))
  }

  private func accessibilityValue(for window: RateWindow) -> String {
    var value = "\(UsageFormatter.percent(window.remainingPercent)) left, \(Theme.statusWord(window.usedPercent))"
    if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
      value += ", resets \(reset)"
    }
    return value
  }

  /// Battery-style: the fill is what's left, matching the "% left" label.
  private func bar(_ remaining: Double) -> some View {
    GeometryReader { geo in
      let fraction = min(1, max(0, remaining / 100))
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Theme.usageTrack)
        Capsule()
          .fill(accent)
          .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
          .animation(.easeOut(duration: 0.4), value: fraction)
      }
    }
    .frame(height: 5)
  }
}
