import SwiftUI

struct NotificationsPreferencesView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    @Bindable var notifications = store.quotaNotifications

    VStack(spacing: 16) {
      PreferencesCard(
        "Quota Alerts",
        subtitle: "Get notified before a provider reaches its usage limit."
      ) {
        PreferencesToggleRow(
          "Quota alerts",
          detail: "Deliver warning, critical, and reset notifications.",
          isOn: $notifications.notificationsEnabled
        )
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

      PreferencesCard(
        "Thresholds",
        subtitle: "Set the usage levels that trigger each alert."
      ) {
        VStack(spacing: 14) {
          PreferencesControlRow("Warning at \(notifications.warningThreshold)%") {
            Stepper(
              "Warning threshold",
              value: $notifications.warningThreshold,
              in: 1 ... max(1, notifications.criticalThreshold - 1)
            )
            .labelsHidden()
            .accessibilityLabel("Warning threshold")
          }
          .disabled(!controlsEnabled)
          PreferencesRowDivider()
          PreferencesControlRow("Critical at \(notifications.criticalThreshold)%") {
            Stepper(
              "Critical threshold",
              value: $notifications.criticalThreshold,
              in: min(100, notifications.warningThreshold + 1) ... 100
            )
            .labelsHidden()
            .accessibilityLabel("Critical threshold")
          }
          .disabled(!controlsEnabled)
        }
      }

      PreferencesCard(
        "Providers",
        subtitle: "Choose which enabled providers can send quota alerts."
      ) {
        VStack(spacing: 14) {
          ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, descriptor in
            HStack(spacing: 13) {
              ProviderIconView(descriptor: descriptor)
              Text(descriptor.metadata.displayName)
                .font(.body.weight(.medium))
              Spacer()
              Toggle(
                "\(descriptor.metadata.displayName) alerts",
                isOn: $notifications[providerEnabled: descriptor.id]
              )
              .labelsHidden()
              .toggleStyle(.switch)
              .tint(.blue)
              .disabled(!controlsEnabled)
            }
            if index < store.providers.count - 1 {
              PreferencesRowDivider()
            }
          }
        }
      }
    }
  }

  private var controlsEnabled: Bool {
    store.quotaNotifications.notificationsEnabled
      && store.quotaNotifications.authorizationStatus.allowsDelivery
  }
}
