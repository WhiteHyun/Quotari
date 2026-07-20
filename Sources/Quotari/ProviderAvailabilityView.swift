import QuotariCore
import SwiftUI

enum ProviderAvailabilityState {
  case loading
  case noAccount
  case error(String)
}

struct ProviderAvailabilityView: View {
  let descriptor: ProviderDescriptor
  let state: ProviderAvailabilityState
  let showSettings: () -> Void
  let retry: () -> Void

  var body: some View {
    switch state {
    case .loading:
      loadingContent
    case .noAccount:
      noAccountContent
    case let .error(message):
      errorContent(message)
    }
  }

  private var loadingContent: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading live usage…")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }

  private var noAccountContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("No account connected", systemImage: "person.crop.circle.badge.exclamationmark")
        .font(.subheadline.weight(.medium))
      Text("Sign in to \(descriptor.metadata.displayName) or add an account in Settings.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Open Settings…", action: showSettings)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }

  private func errorContent(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Live usage unavailable", systemImage: "exclamationmark.triangle.fill")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.orange)
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button("Retry", action: retry)
          .buttonStyle(.borderedProminent)
        Button("Settings…", action: showSettings)
          .buttonStyle(.bordered)
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}

struct ProviderStaleDataNotice: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text("Refresh failed — showing the last live data.")
        .foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Button("Retry", action: retry)
        .buttonStyle(.borderless)
    }
    .font(.caption)
    .help(message)
    .accessibilityHint(message)
  }
}
