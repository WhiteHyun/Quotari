import SwiftUI

/// Keeps the confirmation inside the account popover's window. Presenting a
/// SwiftUI alert here makes the menu-bar window resign key, and
/// MenuBarExtraAccess closes that window before the alert button action runs.
struct ProviderAccountPopoverConfirmationView: View {
  @Binding var confirmation: ProviderAccountPopoverConfirmation?
  let onConfirm: (ProviderAccountPopoverConfirmation) -> Void
  @AccessibilityFocusState private var isTitleFocused: Bool

  var body: some View {
    if let confirmation {
      VStack(alignment: .leading, spacing: 16) {
        Text(L10n.string(key: confirmation.title))
          .font(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($isTitleFocused)
        ScrollView {
          Text(confirmation.message)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize)
        VStack(spacing: 8) {
          Button {
            confirm(confirmation)
          } label: {
            Text(L10n.string(key: confirmation.confirmButtonTitle))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("provider-account-confirmation-primary")

          Button(role: .cancel) {
            self.confirmation = nil
          } label: {
            Text(L10n.string("Cancel"))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("provider-account-confirmation-cancel")
        }
      }
      .padding(16)
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(.isModal)
      .onAppear {
        isTitleFocused = true
      }
    }
  }

  private func confirm(_ confirmation: ProviderAccountPopoverConfirmation) {
    self.confirmation = nil
    onConfirm(confirmation)
  }
}
