import SwiftUI

struct AboutPreferencesView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    Form {
      Section("About") {
        LabeledContent("App", value: "Quotari")
        LabeledContent("Providers", value: "\(store.providers.count)")
        LabeledContent("Updates") {
          Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
            .disabled(!UpdaterController.shared.isAvailable)
        }
        if !UpdaterController.shared.isAvailable {
          Text("Automatic updates are available in packaged releases.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}
