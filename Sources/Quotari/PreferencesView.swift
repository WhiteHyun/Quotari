import AppKit
import Combine
import KeyboardShortcuts
import QuotariCore
import SwiftUI

struct PreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var intervalMinutes: Double = 1
  @Bindable private var loginItems = LoginItemController.shared

  var body: some View {
    @Bindable var store = store

    Form {
      Section("General") {
        Toggle("Launch at Login", isOn: $loginItems.launchesAtLogin)
          .disabled(!loginItems.isAvailable)
        if !loginItems.isAvailable {
          Text("Launch at Login is available in packaged releases.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if loginItems.requiresApproval {
          HStack(alignment: .firstTextBaseline) {
            Text("Approval is required in System Settings › Login Items.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Open System Settings…") { loginItems.openSystemSettings() }
              .controlSize(.small)
          }
        } else if loginItems.serviceNotFound {
          Text("The login item could not be found. Toggling it again or reinstalling the app should restore it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let error = loginItems.lastError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
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
        Text("These switches control providers across Quotari. Quota alerts are configured separately below.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Menu Bar") {
        Toggle("Show remaining quota", isOn: menuBarRemainingBinding)
        Picker("Quota source", selection: menuBarUsageSourceBinding) {
          Text("Most constrained")
            .tag(MenuBarUsageSource.mostConstrained)
          ForEach(store.enabledProviderDescriptors, id: \.id) { descriptor in
            Text(descriptor.metadata.displayName)
              .tag(MenuBarUsageSource.provider(descriptor.id))
          }
        }
        Toggle("Animate mascot", isOn: menuBarAnimationBinding)
        KeyboardShortcuts.Recorder("Open dashboard", name: .toggleDashboard)
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
      Section("Notifications") {
        Toggle("Quota alerts", isOn: notificationsEnabledBinding)
        if let message = store.quotaNotifications.authorizationMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let error = store.quotaNotifications.lastError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
        Stepper(
          "Warning at \(store.quotaNotifications.preferences.warningThreshold)%",
          value: warningThresholdBinding,
          in: 1 ... max(1, store.quotaNotifications.preferences.criticalThreshold - 1)
        )
        .disabled(!notificationControlsEnabled)
        Stepper(
          "Critical at \(store.quotaNotifications.preferences.criticalThreshold)%",
          value: criticalThresholdBinding,
          in: min(100, store.quotaNotifications.preferences.warningThreshold + 1) ... 100
        )
        .disabled(!notificationControlsEnabled)
        ForEach(store.providers, id: \.id) { descriptor in
          Toggle(
            "\(descriptor.metadata.displayName) alerts",
            isOn: notificationProviderBinding(descriptor.id)
          )
          .disabled(!notificationControlsEnabled)
        }
        Text("Provider alert switches only control notifications, not global provider availability.")
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
    .frame(width: 420, height: 620)
    .onAppear {
      intervalMinutes = store.refreshInterval / 60
      loginItems.refreshStatus()
      Task { await store.quotaNotifications.refreshAuthorizationStatus() }
    }
    // Coming back from System Settings (e.g. after approving the login item)
    // re-activates the app; that's the moment to pick up the outside change.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      loginItems.refreshStatus()
      Task { await store.quotaNotifications.refreshAuthorizationStatus() }
    }
    .onChange(of: intervalMinutes) { _, newValue in
      store.refreshInterval = newValue * 60
    }
  }

  private var notificationControlsEnabled: Bool {
    store.quotaNotifications.preferences.isEnabled
      && store.quotaNotifications.authorizationStatus.allowsDelivery
  }

  private var menuBarRemainingBinding: Binding<Bool> {
    Binding(
      get: { store.menuBarPreferences.preferences.showsRemainingPercent },
      set: { store.menuBarPreferences.setShowsRemainingPercent($0) }
    )
  }

  private var menuBarUsageSourceBinding: Binding<MenuBarUsageSource> {
    Binding(
      get: { store.menuBarPreferences.preferences.usageSource },
      set: { store.menuBarPreferences.setUsageSource($0) }
    )
  }

  private var menuBarAnimationBinding: Binding<Bool> {
    Binding(
      get: { store.menuBarPreferences.preferences.animatesMascot },
      set: { store.menuBarPreferences.setAnimatesMascot($0) }
    )
  }

  private var notificationsEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.quotaNotifications.preferences.isEnabled },
      set: { enabled in
        Task { await store.quotaNotifications.setNotificationsEnabled(enabled) }
      }
    )
  }

  private var warningThresholdBinding: Binding<Int> {
    Binding(
      get: { store.quotaNotifications.preferences.warningThreshold },
      set: { warning in
        _ = store.quotaNotifications.updateThresholds(
          warning: warning,
          critical: store.quotaNotifications.preferences.criticalThreshold
        )
      }
    )
  }

  private var criticalThresholdBinding: Binding<Int> {
    Binding(
      get: { store.quotaNotifications.preferences.criticalThreshold },
      set: { critical in
        _ = store.quotaNotifications.updateThresholds(
          warning: store.quotaNotifications.preferences.warningThreshold,
          critical: critical
        )
      }
    )
  }

  private func notificationProviderBinding(_ provider: UsageProvider) -> Binding<Bool> {
    Binding(
      get: { store.quotaNotifications.preferences.enabledProviders.contains(provider) },
      set: { store.quotaNotifications.setProvider(provider, enabled: $0) }
    )
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
    let name = store.accountLabel(for: account)
    guard let detail = account.detail, !detail.isEmpty else {
      return name
    }
    return "\(name) (\(detail))"
  }
}
