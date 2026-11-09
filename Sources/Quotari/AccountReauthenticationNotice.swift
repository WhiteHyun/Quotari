import SwiftUI

/// Explains a saved login the provider has revoked. The raw error tells the
/// user what to run; this says what actually happened to the account.
struct AccountReauthenticationNotice: View {
  let failedSince: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label(L10n.string("Sign-in expired"), systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
      Text(L10n.string(
        "The server rejected this login's refresh token, so Quotari can't renew it. Log in again, or remove it if you no longer use it."
      ))
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let failedSince {
        Text(L10n.string("Failing since \(failedSinceText(failedSince))"))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func failedSinceText(_ date: Date) -> String {
    date.formatted(.dateTime.month().day().hour().minute().locale(L10n.formattingLocale))
  }
}
