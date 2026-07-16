import QuotariCore
import SwiftUI

struct AccountLoginStatusView: View {
  let provider: UsageProvider

  @Environment(UsageStore.self) private var store

  var body: some View {
    if let phase = store.accountLoginPhases[provider] {
      HStack(alignment: .top, spacing: 8) {
        ProgressView()
          .controlSize(.small)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 2) {
          Text(phase.title)
            .font(.caption.weight(.medium))
          if let detail = phase.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        if phase == .waitingForBrowser {
          Button("Cancel") {
            store.cancelAccountLogin(for: provider)
          }
          .controlSize(.small)
        }
      }
    }
    if let error = store.accountLoginErrors[provider] {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
    if let output = store.accountLoginOutputs[provider], !output.isEmpty {
      Text(output)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
