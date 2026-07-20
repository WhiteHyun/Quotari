import QuotariCore
import SwiftUI

struct ProviderStatusSection: View {
  @Environment(\.openURL) private var openURL

  let descriptors: [ProviderDescriptor]
  let controller: ProviderStatusController

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Provider Status")
          .font(.subheadline.weight(.semibold))
        Spacer()
        if controller.isRefreshing {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 10)
      .padding(.bottom, 5)

      ForEach(descriptors, id: \.id) { descriptor in
        statusRow(descriptor)
        if let incident = controller.statuses[descriptor.id]?.incident {
          incidentRow(incident, descriptor: descriptor)
        }
      }
      .padding(.bottom, 6)
    }
  }

  private func statusRow(_ descriptor: ProviderDescriptor) -> some View {
    let state = controller.statuses[descriptor.id]?.state ?? .unknown
    return Button {
      openURL(controller.statuses[descriptor.id]?.statusPageURL ?? descriptor.id.statusPageURL)
    } label: {
      HStack(spacing: 8) {
        Circle()
          .fill(color(for: state))
          .frame(width: 7, height: 7)
        Text(descriptor.metadata.displayName)
        Spacer()
        Text(title(for: state, provider: descriptor.id))
          .foregroundStyle(.secondary)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .font(.footnote)
      .padding(.horizontal, 14)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens the official status page")
  }

  private func incidentRow(
    _ incident: ProviderStatusIncident,
    descriptor: ProviderDescriptor
  ) -> some View {
    Button {
      openURL(incident.url)
    } label: {
      HStack(alignment: .top, spacing: 7) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(color(for: controller.statuses[descriptor.id]?.state ?? .unknown))
          .padding(.top, 1)
        Text(incident.name)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 4)
        Image(systemName: "arrow.up.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
          .padding(.top, 2)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(
        color(for: controller.statuses[descriptor.id]?.state ?? .unknown).opacity(0.1),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .padding(.horizontal, 8)
      .padding(.bottom, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens incident details")
  }

  private func title(for state: ProviderServiceState, provider: UsageProvider) -> String {
    switch state {
    case .unknown:
      controller.isRefreshing && !controller.failedProviders.contains(provider)
        ? "Checking…"
        : "Unavailable"
    case .operational: "Operational"
    case .degradedPerformance: "Degraded"
    case .partialOutage: "Partial outage"
    case .majorOutage: "Major outage"
    }
  }

  private func color(for state: ProviderServiceState) -> Color {
    switch state {
    case .unknown: .secondary
    case .operational: .green
    case .degradedPerformance: .yellow
    case .partialOutage: .orange
    case .majorOutage: .red
    }
  }
}
