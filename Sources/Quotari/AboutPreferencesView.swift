import SwiftUI

struct AboutPreferencesView: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.appVersionInfo) private var appVersionInfo

  var body: some View {
    VStack(spacing: 16) {
      PreferencesCard(
        "About Quotari",
        subtitle: "Your Claude and Codex quota companion for the macOS menu bar."
      ) {
        HStack(spacing: 16) {
          Image(nsImage: IconRenderer.mascotArtwork(frame: 0))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
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
          PreferencesControlRow("Version") {
            Text(appVersionInfo?.displayVersion ?? "Not available")
              .foregroundStyle(.secondary)
          }
          PreferencesRowDivider()
          PreferencesControlRow("Providers") {
            Text("\(store.providers.count)")
              .foregroundStyle(.secondary)
          }
          PreferencesRowDivider()
          PreferencesControlRow("Updates") {
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
