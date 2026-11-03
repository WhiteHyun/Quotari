import Foundation
import SwiftUI

/// How quota rows say when a window resets.
struct ResetTimePreferencesCard: View {
  @Bindable var store: UsageStore

  var body: some View {
    PreferencesCard(
      L10n.string("Dashboard"),
      subtitle: L10n.string("Choose how quota rows show when they reset.")
    ) {
      PreferencesControlRow(L10n.string("Reset time"), detail: example) {
        Picker(L10n.string("Reset time"), selection: $store.resetTimeStyle) {
          Text(L10n.string("Countdown")).tag(ResetTimeStyle.countdown)
          Text(L10n.string("Clock time")).tag(ResetTimeStyle.clockTime)
          Text(L10n.string("Both")).tag(ResetTimeStyle.both)
        }
        .labelsHidden()
        .frame(width: 190, alignment: .trailing)
      }
    }
  }

  /// The selected style applied to a reset 2h 13m away.
  private var example: String? {
    let now = Date()
    return LocalizedUsageFormatter.resetPhrase(
      to: now.addingTimeInterval(2 * 3600 + 13 * 60 + 30),
      style: store.resetTimeStyle,
      now: now
    ).map { L10n.string("Resets \($0)") }
  }
}
