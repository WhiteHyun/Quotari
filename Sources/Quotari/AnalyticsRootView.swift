import QuotariCore
import SwiftUI

/// The Analytics window: one provider's local usage in depth, its quota
/// history, and export.
struct AnalyticsRootView: View {
  @Environment(UsageStore.self) private var store
  @Bindable var model: AnalyticsWindowModel

  var body: some View {
    VStack(spacing: 0) {
      toolbar
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          insightsContent
          if followsDashboard {
            AnalyticsQuotaHistoryView(provider: provider, accent: accent)
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 680, minHeight: 480)
    .background(Color(nsColor: .windowBackgroundColor))
    .task(id: model.context) {
      await loadOtherAccount()
    }
  }

  private var provider: UsageProvider {
    model.context.provider
  }

  private var descriptor: ProviderDescriptor? {
    store.providers.first { $0.id == provider }
  }

  private var accent: Color {
    guard let rgb = descriptor?.metadata.accent else { return .accentColor }
    return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
  }

  private var selectedAccount: ProviderAccount? {
    guard let id = model.context.accountID else { return nil }
    return store.accounts[provider]?.first { $0.id == id }
  }

  /// Whether the window shows the dashboard's own account, whose insights
  /// and quota history the store already keeps current.
  private var followsDashboard: Bool {
    guard let selectedAccount else { return true }
    return selectedAccount.id == store.activeAccount(for: provider)?.id
  }

  private var summary: UsageInsightsSummary? {
    if followsDashboard {
      return store.usageInsightsState(for: provider).summary
    }
    guard case let .loaded(summary) = model.otherAccountState else { return nil }
    return summary
  }

  private var toolbar: some View {
    HStack(spacing: 16) {
      Picker(L10n.string("Provider"), selection: $model.context.provider) {
        ForEach(store.enabledProviderDescriptors, id: \.id) { descriptor in
          Text(descriptor.metadata.displayName).tag(descriptor.id)
        }
      }
      .fixedSize()
      .onChange(of: model.context.provider) {
        model.context.accountID = nil
      }
      Picker(L10n.string("Account"), selection: $model.context.accountID) {
        Text(L10n.string("Dashboard account")).tag(String?.none)
        ForEach(store.accounts[provider] ?? []) { account in
          Text(store.accountLabel(for: account)).tag(Optional(account.id))
        }
      }
      .frame(maxWidth: 280)
      Spacer()
      Picker(L10n.string("Period"), selection: $model.context.period) {
        Text(L10n.string("7D")).tag(UsageInsightsPeriod.sevenDays)
        Text(L10n.string("30D")).tag(UsageInsightsPeriod.thirtyDays)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    }
  }

  @ViewBuilder
  private var insightsContent: some View {
    if let summary, let presentation = UsageInsightsPresentation(summary: summary, period: model.context.period) {
      AnalyticsInsightsSections(
        summary: summary,
        presentation: presentation,
        accent: accent,
        export: store.usageExport(for: summary)
      )
    } else {
      AnalyticsEmptyState(isLoading: isLoading, accountHasNoLogs: model.otherAccountState == .unavailable)
    }
  }

  private var isLoading: Bool {
    if followsDashboard {
      if case .loading = store.usageInsightsState(for: provider) {
        return true
      }
      return false
    }
    return model.otherAccountState == .loading || model.otherAccountState == .idle
  }

  private func loadOtherAccount() async {
    guard !followsDashboard, let selectedAccount else {
      model.otherAccountState = .idle
      return
    }
    model.otherAccountState = .loading
    let loaded = await store.analyticsInsights(provider: provider, account: selectedAccount)
    guard !Task.isCancelled else { return }
    model.otherAccountState = loaded.map(AnalyticsAccountState.loaded) ?? .unavailable
  }
}

private struct AnalyticsEmptyState: View {
  let isLoading: Bool
  let accountHasNoLogs: Bool

  var body: some View {
    VStack(spacing: 8) {
      if isLoading {
        ProgressView()
        Text(L10n.string("Reading local usage…"))
      } else if accountHasNoLogs {
        Image(systemName: "tray")
          .font(.title2)
        Text(L10n.string("No local logs can be attributed to this account."))
      } else {
        Image(systemName: "chart.bar")
          .font(.title2)
        Text(L10n.string("No local usage recorded yet."))
      }
    }
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, minHeight: 200)
  }
}
