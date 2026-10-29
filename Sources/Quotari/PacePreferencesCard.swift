import SwiftUI

/// How the dashboard projects quota use.
struct PacePreferencesCard: View {
  @Bindable var store: UsageStore

  var body: some View {
    PreferencesCard(
      L10n.string("Pace"),
      subtitle: L10n.string("Tune how the dashboard projects quota use.")
    ) {
      PreferencesToggleRow(
        L10n.string("Weekday-only weekly pace"),
        detail: L10n.string("Leave weekends out when judging whether the weekly quota will last."),
        isOn: $store.paceCountsWeekdaysOnly
      )
    }
  }
}
