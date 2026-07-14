import KeyboardShortcuts
import SwiftUI

struct GeneralPreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var intervalMinutes: Double = 1
  @Bindable private var loginItems = LoginItemController.shared

  var body: some View {
    @Bindable var menuBarPreferences = store.menuBarPreferences

    Form {
      Section("General") {
        Toggle("Launch at Login", isOn: $loginItems.launchesAtLogin)
          .disabled(!loginItems.isAvailable)
        loginItemStatus
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

      Section("Menu Bar") {
        Toggle("Show remaining quota", isOn: $menuBarPreferences.showsRemainingPercent)
        Picker("Quota source", selection: $menuBarPreferences.usageSource) {
          Text("Most constrained")
            .tag(MenuBarUsageSource.mostConstrained)
          ForEach(store.enabledProviderDescriptors, id: \.id) { descriptor in
            Text(descriptor.metadata.displayName)
              .tag(MenuBarUsageSource.provider(descriptor.id))
          }
        }
        Toggle("Animate mascot", isOn: $menuBarPreferences.animatesMascot)
        KeyboardShortcuts.Recorder("Open dashboard", name: .toggleDashboard)
      }
    }
    .formStyle(.grouped)
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
