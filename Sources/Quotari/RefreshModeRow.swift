import SwiftUI

/// Chooses between adaptive and fixed refresh in the Refresh settings card.
struct RefreshModeRow: View {
  @Bindable var store: UsageStore

  var body: some View {
    PreferencesRowDivider()
    PreferencesControlRow(L10n.string("Refresh mode"), detail: detail) {
      Picker(L10n.string("Refresh mode"), selection: $store.refreshMode) {
        Text(L10n.string("Adaptive")).tag(RefreshMode.adaptive)
        Text(L10n.string("Fixed")).tag(RefreshMode.fixed)
      }
      .labelsHidden()
      .frame(width: 190, alignment: .trailing)
    }
  }

  private var detail: String {
    switch store.refreshMode {
    case .adaptive:
      L10n.string("Faster while Claude Code or Codex is running or quota is moving; slower while idle.")
    case .fixed:
      L10n.string("Always refresh at the interval above.")
    }
  }
}
