import SwiftUI

/// Settings rows that shape the quota value beside the menu-bar mascot.
struct MenuBarQuotaDisplayRows: View {
  @Bindable var menuBarPreferences: MenuBarPreferencesController

  var body: some View {
    PreferencesControlRow(
      L10n.string("Quota window"),
      detail: L10n.string("Choose which limit drives the menu-bar percentage.")
    ) {
      Picker(L10n.string("Quota window"), selection: $menuBarPreferences.quotaWindow) {
        Text(L10n.string("Automatic")).tag(MenuBarQuotaWindow.automatic)
        Text(L10n.string("Session")).tag(MenuBarQuotaWindow.session)
        Text(L10n.string("Weekly")).tag(MenuBarQuotaWindow.weekly)
      }
      .labelsHidden()
      .frame(width: 190, alignment: .trailing)
    }
    // The window also sets the mascot's animation pace, so it stays enabled.
    PreferencesRowDivider()
    PreferencesControlRow(
      L10n.string("Show as"),
      detail: L10n.string("Show the percentage left, or the percentage used marked with ↑.")
    ) {
      Picker(L10n.string("Show as"), selection: $menuBarPreferences.quotaPresentation) {
        Text(L10n.string("Remaining")).tag(MenuBarQuotaPresentation.remaining)
        Text(L10n.string("Used")).tag(MenuBarQuotaPresentation.used)
      }
      .labelsHidden()
      .frame(width: 190, alignment: .trailing)
    }
    .disabled(!menuBarPreferences.showsRemainingPercent)
  }
}
