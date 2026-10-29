import SwiftUI

/// Opt-in Claude Code hooks for session alerts (ADR 0004).
struct SessionAlertsPreferencesCard: View {
  @Bindable var sessionActivity: SessionActivityController
  let notificationsEnabled: Bool

  var body: some View {
    PreferencesCard(
      L10n.string("Claude Code Sessions"),
      subtitle: L10n.string("Get notified when a session needs your input or finishes.")
    ) {
      PreferencesToggleRow(
        L10n.string("Session alerts"),
        detail: L10n.string("Adds Quotari hooks to Claude Code's settings.json. Turning this off removes them."),
        isOn: $sessionActivity.hooksEnabled
      )
      // Removing the hooks always works; adding them needs the packaged CLI
      // and notifications.
      .disabled(!sessionActivity.hooksInstalled && (!notificationsEnabled || sessionActivity.hookCommand == nil))
      if sessionActivity.hookCommand == nil {
        Text(L10n.string("Available in the packaged app."))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let error = sessionActivity.hookError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }
}
