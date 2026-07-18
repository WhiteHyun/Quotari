import SwiftUI

struct AboutPreferencesView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    VStack(spacing: 16) {
      PreferencesCard(
        "About Quotari",
        subtitle: "Your Claude and Codex quota companion for the macOS menu bar."
      ) {
        HStack(spacing: 16) {
          Image(nsImage: IconRenderer.mascotIcon(frame: 0))
            .resizable()
            .interpolation(.high)
            .frame(width: 52, height: 52)
          VStack(alignment: .leading, spacing: 3) {
            Text("Quotari")
              .font(.title2.weight(.bold))
            Text("Monitor usage, accounts, and local estimated cost at a glance.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }

      PreferencesCard("Details") {
        VStack(spacing: 14) {
          LabeledContent("App", value: "Quotari")
          PreferencesRowDivider()
          LabeledContent("Providers", value: "\(store.providers.count)")
          PreferencesRowDivider()
          LabeledContent("Updates") {
            Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
              .disabled(!UpdaterController.shared.isAvailable)
          }
          if !UpdaterController.shared.isAvailable {
            Text("Automatic updates are available in packaged releases.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }
}
