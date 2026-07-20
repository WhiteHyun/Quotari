import QuotariCore
import SwiftUI

struct ProviderStatusPopover: View {
  @Environment(\.openURL) private var openURL

  let descriptors: [ProviderDescriptor]
  let controller: ProviderStatusController
  var refresh: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("Provider Status")
          .font(.headline)
        Spacer()
        if controller.isRefreshing {
          ProgressView()
            .controlSize(.small)
        } else {
          Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Refresh provider status")
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)

      Divider()

      ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
        providerSection(descriptor)
        if index < descriptors.count - 1 {
          Divider()
            .padding(.leading, 14)
        }
      }
    }
    .frame(width: 300)
  }

  private func providerSection(_ descriptor: ProviderDescriptor) -> some View {
    let status = controller.statuses[descriptor.id]
    let state = status?.state ?? .unknown
    return VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        ProviderIconView(descriptor: descriptor, size: 20)
        Text(descriptor.metadata.displayName)
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 8)
        statusLabel(state, provider: descriptor.id)
      }

      if let status, !status.components.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(status.components) { component in
            componentRow(component)
          }
        }
      } else if controller.isRefreshing, !controller.failedProviders.contains(descriptor.id) {
        Text("Checking service health…")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Text("Detailed service status is unavailable.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if let incident = status?.incident {
        incidentRow(incident, state: state)
      }

      HStack(spacing: 12) {
        linkButton("Usage Dashboard", systemImage: "chart.bar.xaxis") {
          openURL(descriptor.id.usageDashboardURL)
        }
        linkButton("Status Page", systemImage: "arrow.up.right.square") {
          openURL(status?.statusPageURL ?? descriptor.id.statusPageURL)
        }
      }
      .font(.caption)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  private func componentRow(_ component: ProviderStatusComponent) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(color(for: component.state))
        .frame(width: 7, height: 7)
      Text(component.name)
        .lineLimit(1)
      Spacer(minLength: 12)
      Text(title(for: component.state))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .font(.footnote)
    .accessibilityElement(children: .combine)
  }

  private func statusLabel(
    _ state: ProviderServiceState,
    provider: UsageProvider
  ) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color(for: state))
        .frame(width: 7, height: 7)
      Text(title(for: state, provider: provider))
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func incidentRow(_ incident: ProviderStatusIncident, state: ProviderServiceState) -> some View {
    Button {
      openURL(incident.url)
    } label: {
      HStack(alignment: .top, spacing: 7) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(color(for: state))
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
        color(for: state).opacity(0.1),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens incident details")
  }

  private func linkButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(.link)
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

  private func title(for state: ProviderServiceState) -> String {
    switch state {
    case .unknown: "Unknown"
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
