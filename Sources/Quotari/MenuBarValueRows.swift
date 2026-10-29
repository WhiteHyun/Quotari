import QuotariCore
import SwiftUI

/// Settings rows that choose what the menu bar shows beside the mascot.
struct MenuBarValueRows: View {
  @Bindable var menuBarPreferences: MenuBarPreferencesController
  let enabledProviders: [ProviderDescriptor]

  var body: some View {
    PreferencesControlRow(
      L10n.string("Menu-bar value"),
      detail: L10n.string("Choose what appears beside the mascot.")
    ) {
      Picker(L10n.string("Menu-bar value"), selection: $menuBarPreferences.valueMode) {
        Text(L10n.string("Hidden")).tag(MenuBarValueMode.hidden)
        Text(L10n.string("Remaining quota")).tag(MenuBarValueMode.remainingQuota)
        Text(L10n.string("Today cost")).tag(MenuBarValueMode.todayCost)
      }
      .labelsHidden()
      .frame(width: 190, alignment: .trailing)
    }
    if menuBarPreferences.valueMode == .todayCost {
      PreferencesRowDivider()
      PreferencesControlRow(
        L10n.string("Cost source"),
        detail: L10n.string("Today's local cost estimate for this provider's selected account.")
      ) {
        Picker(L10n.string("Cost source"), selection: $menuBarPreferences.costSource) {
          Text(L10n.string("Choose a cost source")).tag(UsageProvider?.none)
          ForEach(costSourceChoices, id: \.id) { choice in
            Text(choice.title).tag(Optional(choice.id))
          }
        }
        .labelsHidden()
        .frame(width: 190, alignment: .trailing)
      }
    }
  }

  /// Enabled providers, plus a disabled selection so the preference survives.
  private var costSourceChoices: [(id: UsageProvider, title: String)] {
    var choices = enabledProviders.map { (id: $0.id, title: $0.metadata.displayName) }
    if let selected = menuBarPreferences.costSource,
       !choices.contains(where: { $0.id == selected }) {
      let name = ProviderRegistry.descriptor(for: selected).metadata.displayName
      choices.append((id: selected, title: L10n.string("\(name) (Unavailable)")))
    }
    return choices
  }
}
