import QuotariCore
import SwiftUI

struct UsageInsightsDisclosure: View {
  let state: UsageInsightsLoadState
  let accent: Color
  @Binding var isExpanded: Bool
  @Binding var period: UsageInsightsPeriod

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let summary = state.summary {
        UsageInsightsSummaryView(
          summary: summary,
          accent: accent,
          isExpanded: $isExpanded,
          period: $period,
          isRefreshing: isRefreshing,
          refreshFailed: refreshFailed
        )
      } else {
        statusContent
      }
    }
  }

  private var isRefreshing: Bool {
    if case .loading = state {
      return true
    }
    return false
  }

  private var refreshFailed: Bool {
    if case .failed = state {
      return true
    }
    return false
  }

  @ViewBuilder
  private var statusContent: some View {
    switch state {
    case .loading:
      statusRow(
        title: L10n.string("Usage insights"),
        detail: L10n.string("Analyzing local usage…"),
        showsProgress: true
      )
    case .empty:
      statusRow(
        title: L10n.string("Usage insights"),
        detail: L10n.string("No local usage yet"),
        showsProgress: false
      )
    case .failed:
      statusRow(
        title: L10n.string("Usage insights"),
        detail: L10n.string("Local insights unavailable"),
        showsProgress: false
      )
    case .idle, .loaded:
      EmptyView()
    }
  }

  private func statusRow(
    title: String,
    detail: String,
    showsProgress: Bool
  ) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if showsProgress {
        ProgressView()
          .controlSize(.small)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct UsageInsightsSummaryView: View {
  let presentation: UsageInsightsPresentation?
  let accent: Color
  @Binding var isExpanded: Bool
  @Binding var period: UsageInsightsPeriod
  let isRefreshing: Bool
  let refreshFailed: Bool

  init(
    summary: UsageInsightsSummary,
    accent: Color,
    isExpanded: Binding<Bool>,
    period: Binding<UsageInsightsPeriod>,
    isRefreshing: Bool,
    refreshFailed: Bool
  ) {
    presentation = UsageInsightsPresentation(summary: summary, period: period.wrappedValue)
    self.accent = accent
    _isExpanded = isExpanded
    _period = period
    self.isRefreshing = isRefreshing
    self.refreshFailed = refreshFailed
  }

  var body: some View {
    if let presentation {
      VStack(alignment: .leading, spacing: 10) {
        header
        if isExpanded {
          expandedContent(presentation)
        } else {
          collapsedContent(presentation)
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 5) {
          Text(L10n.string("Usage insights"))
            .font(.subheadline.weight(.semibold))
          if isRefreshing {
            ProgressView()
              .controlSize(.mini)
          }
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        isExpanded
          ? L10n.string("Collapse usage insights")
          : L10n.string("Expand usage insights")
      )

      Spacer(minLength: 4)
      if isExpanded {
        Picker(L10n.string("Usage period"), selection: $period) {
          Text(L10n.string("7D")).tag(UsageInsightsPeriod.sevenDays)
          Text(L10n.string("30D")).tag(UsageInsightsPeriod.thirtyDays)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 104)
        .accessibilityLabel(L10n.string("Usage period"))
      }
    }
  }

  private func collapsedContent(_ presentation: UsageInsightsPresentation) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) {
        isExpanded = true
      }
    } label: {
      HStack(spacing: 12) {
        compactMetric(label: L10n.string("Today"), value: presentation.todayValue)
        Divider()
          .frame(height: 28)
        compactMetric(label: presentation.periodLabel, value: presentation.periodValue)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.string("Expand usage insights"))
    .accessibilityValue(presentation.compactAccessibilityValue)
  }

  private func expandedContent(_ presentation: UsageInsightsPresentation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 28) {
        headlineMetric(label: L10n.string("Today"), value: presentation.todayValue)
        headlineMetric(label: presentation.periodLabel, value: presentation.periodValue)
      }
      UsageInsightsChart(presentation: presentation, accent: accent)
      if !presentation.insightCells.isEmpty {
        insightGrid(presentation.insightCells)
      }
      coverage(presentation)
    }
  }

  private func headlineMetric(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.weight(.semibold).monospacedDigit())
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func compactMetric(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.weight(.semibold).monospacedDigit())
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func insightGrid(
    _ cells: [UsageInsightsPresentation.InsightCell]
  ) -> some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: min(3, cells.count)
      ),
      spacing: 8
    ) {
      ForEach(cells) { cell in
        HStack(spacing: 6) {
          Image(systemName: cell.systemImage)
            .foregroundStyle(accent)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 0) {
            Text(cell.title)
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text(cell.value)
              .font(.caption.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.middle)
              .help(cell.value)
          }
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.vertical, 8)
    .overlay(alignment: .top) { Divider() }
    .overlay(alignment: .bottom) { Divider() }
  }

  private func coverage(_ presentation: UsageInsightsPresentation) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: presentation.coverageIsWarning ? "exclamationmark.circle" : "checkmark.circle")
        .foregroundStyle(presentation.coverageIsWarning ? .orange : .secondary)
      Text(presentation.coverageLabel)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .help(presentation.coverageHelp)
    .accessibilityElement(children: .combine)
    .overlay(alignment: .bottomLeading) {
      if refreshFailed {
        Text(L10n.string("Refresh failed — showing cached insights."))
          .font(.caption2)
          .foregroundStyle(.orange)
          .offset(y: 16)
      }
    }
    .padding(.bottom, refreshFailed ? 14 : 0)
  }
}
