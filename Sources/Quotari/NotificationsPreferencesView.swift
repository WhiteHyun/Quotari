import SwiftUI

struct NotificationsPreferencesView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    @Bindable var notifications = store.quotaNotifications

    Form {
      Section("Quota Alerts") {
        Toggle("Quota alerts", isOn: $notifications.notificationsEnabled)
        if let message = notifications.authorizationMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let error = notifications.lastError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("Thresholds") {
        Stepper(
          "Warning at \(notifications.warningThreshold)%",
          value: $notifications.warningThreshold,
          in: 1 ... max(1, notifications.criticalThreshold - 1)
        )
        .disabled(!controlsEnabled)
        Stepper(
          "Critical at \(notifications.criticalThreshold)%",
          value: $notifications.criticalThreshold,
          in: min(100, notifications.warningThreshold + 1) ... 100
        )
        .disabled(!controlsEnabled)
      }

      Section("Providers") {
        ForEach(store.providers, id: \.id) { descriptor in
          Toggle(
            "\(descriptor.metadata.displayName) alerts",
            isOn: $notifications[providerEnabled: descriptor.id]
          )
          .disabled(!controlsEnabled)
        }
        Text("These switches only control alerts, not global provider availability.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var controlsEnabled: Bool {
    store.quotaNotifications.notificationsEnabled
      && store.quotaNotifications.authorizationStatus.allowsDelivery
  }
}
