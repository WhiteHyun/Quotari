import KeyboardShortcuts
import SwiftUI

struct GeneralPreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var intervalMinutes: Double = 1
  @Bindable private var loginItems = LoginItemController.shared

  var body: some View {
    @Bindable var menuBarPreferences = store.menuBarPreferences

    VStack(spacing: 16) {
      PreferencesCard(
        "General",
        subtitle: "Choose how Quotari starts and stays available."
      ) {
        PreferencesToggleRow(
          "Launch at Login",
          detail: "Keep quota status ready from the moment you sign in.",
          isOn: $loginItems.launchesAtLogin
        )
        .disabled(!loginItems.isAvailable)
        loginItemStatus
      }

      PreferencesCard(
        "Refresh",
        subtitle: "Control how often Quotari checks provider usage."
      ) {
        VStack(alignment: .leading, spacing: 10) {
          Slider(value: $intervalMinutes, in: 1 ... 30, step: 1) {
            Text("Refresh interval")
          } minimumValueLabel: {
            Text("1m")
          } maximumValueLabel: {
            Text("30m")
          }
          Text("Every \(Int(intervalMinutes)) minute(s)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      PreferencesCard(
        "Menu Bar",
        subtitle: "Tune the compact status shown beside the Quotari mascot."
      ) {
        VStack(spacing: 16) {
          PreferencesToggleRow(
            "Show remaining quota",
            detail: "Display the current remaining percentage in the menu bar.",
            isOn: $menuBarPreferences.showsRemainingPercent
          )
          PreferencesRowDivider()
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("Quota source")
              Text("Choose which provider drives the menu-bar percentage.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Quota source", selection: $menuBarPreferences.usageSource) {
              Text("Most constrained")
                .tag(MenuBarUsageSource.mostConstrained)
              ForEach(store.enabledProviderDescriptors, id: \.id) { descriptor in
                Text(descriptor.metadata.displayName)
                  .tag(MenuBarUsageSource.provider(descriptor.id))
              }
            }
            .labelsHidden()
            .frame(width: 190)
          }
          PreferencesRowDivider()
          PreferencesToggleRow(
            "Animate mascot",
            detail: "Let the flame react as usage approaches its limit.",
            isOn: $menuBarPreferences.animatesMascot
          )
          PreferencesRowDivider()
          KeyboardShortcuts.Recorder("Open dashboard", name: .toggleDashboard)
        }
      }
    }
    .onAppear { intervalMinutes = store.refreshInterval / 60 }
    .onChange(of: intervalMinutes) { _, newValue in
      store.refreshInterval = newValue * 60
    }
  }

  @ViewBuilder private var loginItemStatus: some View {
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
}
