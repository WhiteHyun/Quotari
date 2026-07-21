import SwiftUI

struct AboutPreferencesView: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.appVersionInfo) private var appVersionInfo

  var body: some View {
    VStack(spacing: 16) {
      PreferencesCard(
        L10n.string("About Quotari"),
        subtitle: L10n.string("Your Claude and Codex quota companion for the macOS menu bar.")
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
            Text(L10n.string("Monitor usage, accounts, and local estimated cost at a glance."))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }

      PreferencesCard(L10n.string("Details")) {
        VStack(spacing: 14) {
          PreferencesControlRow(L10n.string("Version")) {
            Text(appVersionInfo?.displayVersion ?? L10n.string("Not available"))
              .foregroundStyle(.secondary)
          }
          PreferencesRowDivider()
          PreferencesControlRow(L10n.string("Providers")) {
            Text("\(store.providers.count)")
              .foregroundStyle(.secondary)
          }
          PreferencesRowDivider()
          PreferencesControlRow(L10n.string("Updates")) {
            Button(L10n.string("Check for Updates…")) { UpdaterController.shared.checkForUpdates() }
              .disabled(!UpdaterController.shared.isAvailable)
          }
          if !UpdaterController.shared.isAvailable {
            Text(L10n.string("Automatic updates are available in packaged releases."))
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }
}
