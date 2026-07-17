import QuotariCore
import SwiftUI

struct AccountLoginStatusView: View {
  let provider: UsageProvider

  @Environment(UsageStore.self) private var store
  @FocusState private var isAuthenticationCodeFocused: Bool
  @State private var authenticationCode = ""

  var body: some View {
    content
      .onChange(of: store.accountLoginPhases[provider]) { _, newPhase in
        guard newPhase != .waitingForAuthenticationCode else {
          isAuthenticationCodeFocused = true
          return
        }
        authenticationCode = ""
        isAuthenticationCodeFocused = false
      }
  }

  @ViewBuilder
  private var content: some View {
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
        if phase.allowsCancellation {
          Button("Cancel") {
            store.cancelAccountLogin(for: provider)
          }
          .controlSize(.small)
        }
      }
      if phase == .waitingForAuthenticationCode {
        HStack(spacing: 8) {
          SecureField("Authentication Code", text: $authenticationCode)
            .textFieldStyle(.roundedBorder)
            .focused($isAuthenticationCodeFocused)
            .onSubmit(submitAuthenticationCode)
          Button("Submit", action: submitAuthenticationCode)
            .disabled(authenticationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { isAuthenticationCodeFocused = true }
      }
    }
    if let error = store.accountLoginErrors[provider] {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
    if let output = store.accountLoginOutputs[provider], !output.isEmpty {
      ScrollView(.vertical) {
        Text(output)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 140)
    }
  }

  private func submitAuthenticationCode() {
    if store.submitAccountLoginAuthenticationCode(authenticationCode, for: provider) {
      authenticationCode = ""
      isAuthenticationCodeFocused = false
    }
  }
}
