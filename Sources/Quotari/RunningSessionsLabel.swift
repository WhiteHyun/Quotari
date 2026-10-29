import SwiftUI

/// How many CLI sessions are running, from process detection.
struct RunningSessionsLabel: View {
  let sessions: Int

  var body: some View {
    if sessions > 0 {
      Label(L10n.string("\(sessions) running"), systemImage: "terminal")
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(L10n.string("\(sessions) sessions running"))
    }
  }
}
