import QuotariCore
import SwiftUI

struct ProviderStatusPresentation: Equatable {
  let state: ProviderServiceState

  var title: String {
    switch state {
    case .unknown: "Unknown"
    case .operational: "Operational"
    case .degradedPerformance: "Degraded"
    case .partialOutage: "Partial outage"
    case .majorOutage: "Major outage"
    }
  }

  var showsIssueBadge: Bool {
    switch state {
    case .degradedPerformance, .partialOutage, .majorOutage: true
    case .unknown, .operational: false
    }
  }

  var color: Color {
    switch state {
    case .unknown: .secondary
    case .operational: .green
    case .degradedPerformance: .yellow
    case .partialOutage: .orange
    case .majorOutage: .red
    }
  }
}

struct ProviderStatusDisclosureButton: View {
  let descriptor: ProviderDescriptor
  let controller: ProviderStatusController

  @State private var isPresented = false

  private var status: ProviderServiceStatus? {
    controller.status(for: descriptor.id)
  }

  private var presentation: ProviderStatusPresentation? {
    status.map { ProviderStatusPresentation(state: $0.state) }
  }

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      statusLabel
    }
    .buttonStyle(.plain)
    .popover(
      isPresented: $isPresented,
      attachmentAnchor: .rect(.bounds),
      arrowEdge: .leading
    ) {
      ProviderStatusPopover(
        descriptor: descriptor,
        controller: controller
      )
    }
    .help(helpText)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Shows live service health and the official status page")
  }

  @ViewBuilder
  private var statusLabel: some View {
    if controller.isRefreshing(descriptor.id), status == nil {
      ProgressView()
        .controlSize(.mini)
        .frame(width: 18, height: 18)
        .padding(.horizontal, 4)
    } else if let presentation, presentation.showsIssueBadge {
      HStack(spacing: 5) {
        Circle()
          .fill(presentation.color)
          .frame(width: 7, height: 7)
        Text(presentation.title)
          .lineLimit(1)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.primary)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(
        presentation.color.opacity(0.14),
        in: Capsule()
      )
    } else {
      Image(systemName: "waveform.path.ecg")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
  }

  private var helpText: String {
    if let presentation {
      return "\(descriptor.metadata.displayName) service status: \(presentation.title)"
    }
    return "Check \(descriptor.metadata.displayName) service status"
  }

  private var accessibilityLabel: String {
    if let presentation {
      return "\(descriptor.metadata.displayName) service status, \(presentation.title)"
    }
    return "Check \(descriptor.metadata.displayName) service status"
  }
}

struct ProviderStatusPopover: View {
  let descriptor: ProviderDescriptor
  let controller: ProviderStatusController

  var body: some View {
    ProviderStatusDetailView(
      descriptor: descriptor,
      controller: controller,
      refresh: {
        Task {
          await controller.refresh(descriptor.id, forceRefresh: true)
        }
      }
    )
    .task(id: descriptor.id) {
      await controller.refresh(descriptor.id)
    }
  }
}

struct ProviderStatusDetailView: View {
  @Environment(\.openURL) private var openURL

  let descriptor: ProviderDescriptor
  let controller: ProviderStatusController
  var refresh: () -> Void = {}

  private var status: ProviderServiceStatus? {
    controller.status(for: descriptor.id)
  }

  private var presentation: ProviderStatusPresentation? {
    status.map { ProviderStatusPresentation(state: $0.state) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.vertical, 11)

      Divider()

      content
        .padding(.horizontal, 14)
        .padding(.vertical, 11)

      Divider()

      links
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    .frame(width: 300)
  }

  private var header: some View {
    HStack(spacing: 9) {
      ProviderIconView(descriptor: descriptor, size: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(descriptor.metadata.displayName) Status")
          .font(.headline)
        if let status {
          TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(
              ProviderFreshness(
                updatedAt: status.updatedAt,
                now: context.date,
                refreshInterval: 300
              ).updatedText
            )
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text(controller.isRefreshing(descriptor.id) ? "Checking service health…" : "Not checked yet")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if controller.isRefreshing(descriptor.id) {
        ProgressView()
          .controlSize(.small)
      } else if let presentation {
        statusBadge(presentation)
      } else {
        Button(action: refresh) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Check provider status")
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let status {
      VStack(alignment: .leading, spacing: 9) {
        if status.components.isEmpty {
          Text("Detailed component status is unavailable.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          ForEach(status.components) { component in
            componentRow(component)
          }
        }

        if let incident = status.incident {
          incidentRow(incident, state: status.state)
            .padding(.top, 2)
        }
      }
    } else if controller.isRefreshing(descriptor.id) {
      Text("Checking the official provider status…")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if controller.failedProviders.contains(descriptor.id) {
      VStack(alignment: .leading, spacing: 7) {
        Text("Service status is unavailable.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Try Again", action: refresh)
          .buttonStyle(.link)
      }
    } else {
      Text("Check the provider’s live service health when you need it.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var links: some View {
    HStack(spacing: 14) {
      Button {
        openURL(descriptor.id.usageDashboardURL)
      } label: {
        Label("Usage Dashboard", systemImage: "chart.bar.xaxis")
      }
      Button {
        openURL(status?.statusPageURL ?? descriptor.id.statusPageURL)
      } label: {
        Label("Status Page", systemImage: "arrow.up.right.square")
      }
    }
    .font(.caption)
    .buttonStyle(.link)
  }

  private func componentRow(_ component: ProviderStatusComponent) -> some View {
    let componentPresentation = ProviderStatusPresentation(state: component.state)
    return HStack(spacing: 8) {
      Circle()
        .fill(componentPresentation.color)
        .frame(width: 7, height: 7)
      Text(component.name)
        .lineLimit(1)
      Spacer(minLength: 12)
      Text(componentPresentation.title)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .font(.footnote)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(component.name), \(componentPresentation.title)")
  }

  private func statusBadge(_ presentation: ProviderStatusPresentation) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(presentation.color)
        .frame(width: 7, height: 7)
      Text(presentation.title)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func incidentRow(
    _ incident: ProviderStatusIncident,
    state: ProviderServiceState
  ) -> some View {
    let incidentPresentation = ProviderStatusPresentation(state: state)
    return Button {
      openURL(incident.url)
    } label: {
      HStack(alignment: .top, spacing: 7) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(incidentPresentation.color)
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
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        incidentPresentation.color.opacity(0.1),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens incident details")
  }
}
