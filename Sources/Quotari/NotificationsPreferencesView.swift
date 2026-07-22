import SwiftUI

struct NotificationsPreferencesView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    @Bindable var notifications = store.quotaNotifications

    VStack(spacing: 16) {
      PreferencesCard(
        L10n.string("Quota Alerts"),
        subtitle: L10n.string("Get notified before a provider reaches its usage limit.")
      ) {
        PreferencesToggleRow(
          L10n.string("Quota alerts"),
          detail: L10n.string("Deliver warning, critical, and reset notifications."),
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
        L10n.string("Thresholds"),
        subtitle: L10n.string("Set the usage levels that trigger each alert.")
      ) {
        VStack(spacing: 14) {
          QuotaThresholdSliderRow(
            L10n.string("Warning threshold"),
            value: $notifications.warningThreshold,
            allowedRange: QuotaThresholdSliderLimits.warningRange(
              critical: notifications.criticalThreshold
            )
          )
          .disabled(!controlsEnabled)
          PreferencesRowDivider()
          QuotaThresholdSliderRow(
            L10n.string("Critical threshold"),
            value: $notifications.criticalThreshold,
            allowedRange: QuotaThresholdSliderLimits.criticalRange(
              warning: notifications.warningThreshold
            )
          )
          .disabled(!controlsEnabled)
        }
      }

      PreferencesCard(
        L10n.string("Providers"),
        subtitle: L10n.string("Choose which enabled providers can send quota alerts.")
      ) {
        VStack(spacing: 14) {
          ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, descriptor in
            HStack(spacing: 13) {
              ProviderIconView(descriptor: descriptor)
              Text(descriptor.metadata.displayName)
                .font(.body.weight(.medium))
              Spacer()
              Toggle(
                L10n.string("\(descriptor.metadata.displayName) alerts"),
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

enum QuotaThresholdSliderLimits {
  static func warningRange(critical: Int) -> ClosedRange<Int> {
    1 ... max(1, critical - 1)
  }

  static func criticalRange(warning: Int) -> ClosedRange<Int> {
    min(100, warning + 1) ... 100
  }

  static func clampedValue(
    _ proposedValue: Double,
    to allowedRange: ClosedRange<Int>
  ) -> Int {
    min(
      max(Int(proposedValue.rounded()), allowedRange.lowerBound),
      allowedRange.upperBound
    )
  }
}

private struct QuotaThresholdSliderRow: View {
  private let fullRange = 1 ... 100

  let title: String
  @Binding var value: Int
  let allowedRange: ClosedRange<Int>

  init(
    _ title: String,
    value: Binding<Int>,
    allowedRange: ClosedRange<Int>
  ) {
    self.title = title
    _value = value
    self.allowedRange = allowedRange
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(remainingQuotaText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 24)
        Text(LocalizedUsageFormatter.percent(Double(value)))
          .font(.body.monospacedDigit().weight(.medium))
          .contentTransition(.numericText(value: Double(value)))
      }

      Slider(value: sliderValue, in: 1 ... 100, step: 1) {
        EmptyView()
      } minimumValueLabel: {
        Text(LocalizedUsageFormatter.percent(Double(fullRange.lowerBound)))
      } maximumValueLabel: {
        Text(LocalizedUsageFormatter.percent(Double(fullRange.upperBound)))
      }
      .labelsHidden()
      .tint(Theme.brandAccent)
      .accessibilityLabel(title)
      .accessibilityValue(LocalizedUsageFormatter.percent(Double(value)))
    }
  }

  private var sliderValue: Binding<Double> {
    Binding(
      get: { Double(value) },
      set: { proposedValue in
        value = QuotaThresholdSliderLimits.clampedValue(
          proposedValue,
          to: allowedRange
        )
      }
    )
  }

  private var remainingQuotaText: String {
    L10n.string(
      "\(LocalizedUsageFormatter.percent(Double(100 - value))) left"
    )
  }
}
