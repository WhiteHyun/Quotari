import QuotariCore
import SwiftUI

/// Keeps an open service incident visible on the card, so an outage can't be
/// mistaken for a quota or sign-in problem.
struct ProviderIncidentNotice: View {
  let outage: ProviderOutage?

  var body: some View {
    if let outage {
      Label(L10n.string("Service incident: \(outage.title)"), systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .lineLimit(2)
    }
  }
}
