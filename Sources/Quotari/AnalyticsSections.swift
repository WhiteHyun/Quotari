import AppKit
import QuotariCore
import SwiftUI
import UniformTypeIdentifiers

struct AnalyticsInsightsSections: View {
  let summary: UsageInsightsSummary
  let presentation: UsageInsightsPresentation
  let accent: Color
  let export: UsageExport

  var body: some View {
    let period = summary.period(presentation.period)
    VStack(alignment: .leading, spacing: 24) {
      metrics
      AnalyticsSection(L10n.string("Daily usage")) {
        UsageInsightsChart(presentation: presentation, accent: accent, height: 200)
      }
      if let period {
        AnalyticsSection(L10n.string("Tokens")) {
          AnalyticsTokenTotals(tokens: period.tokens)
        }
        if !period.models.isEmpty {
          AnalyticsSection(L10n.string("Models")) {
            AnalyticsModelBreakdown(models: period.models)
          }
        }
      }
      AnalyticsSection(L10n.string("Source")) {
        AnalyticsProvenance(summary: summary, presentation: presentation)
      }
      AnalyticsSection(L10n.string("Export")) {
        AnalyticsExportControls(export: export)
      }
    }
  }

  private var metrics: some View {
    HStack(alignment: .top, spacing: 32) {
      AnalyticsMetric(title: L10n.string("Today"), value: presentation.todayValue)
      AnalyticsMetric(title: presentation.periodLabel, value: presentation.periodValue)
      ForEach(presentation.insightCells) { cell in
        AnalyticsMetric(title: cell.title, value: cell.value)
      }
      Spacer(minLength: 0)
    }
  }
}

struct AnalyticsSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content
    }
  }
}

private struct AnalyticsMetric: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title2.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct AnalyticsTokenTotals: View {
  let tokens: UsageTokenBreakdown

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 6) {
      GridRow {
        cell(L10n.string("Input"), tokens.input)
        cell(L10n.string("Output"), tokens.output)
        cell(L10n.string("Cache read"), tokens.cacheRead)
        cell(L10n.string("Cache write"), tokens.cacheWrite)
        cell(L10n.string("Total"), tokens.total)
      }
    }
  }

  private func cell(_ title: String, _ metric: UsageMetric<Int>) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(UsageInsightsPresentation.formattedTokens(metric))
        .font(.body.monospacedDigit())
    }
    .accessibilityElement(children: .combine)
  }
}

private struct AnalyticsModelBreakdown: View {
  let models: [ModelUsageInsight]

  private var ranked: [ModelUsageInsight] {
    models.sorted { lhs, rhs in
      let lhsSpend = lhs.spend.value ?? 0
      let rhsSpend = rhs.spend.value ?? 0
      if lhsSpend != rhsSpend {
        return lhsSpend > rhsSpend
      }
      return (lhs.tokens.total.value ?? 0) > (rhs.tokens.total.value ?? 0)
    }
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(ranked) { model in
        HStack {
          Text(model.modelID)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(model.modelID)
          Spacer()
          Text(UsageInsightsPresentation.formattedTokens(model.tokens.total))
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .trailing)
          Text(UsageInsightsPresentation.formattedSpend(model.spend, currencyCode: "USD"))
            .frame(width: 90, alignment: .trailing)
        }
        .font(.body.monospacedDigit())
        .padding(.vertical, 6)
        Divider()
      }
    }
  }
}

private struct AnalyticsProvenance: View {
  let summary: UsageInsightsSummary
  let presentation: UsageInsightsPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(summary.sourceDescription, systemImage: "doc.text")
      Label(
        summary.accountScope == .exact
          ? L10n.string("Logs that belong to this account")
          : L10n.string("Local logs shared by accounts on this Mac"),
        systemImage: "person.crop.circle"
      )
      Label(
        L10n.string("Updated \(summary.generatedAt.formatted(.relative(presentation: .named)))"),
        systemImage: "clock"
      )
      Label(
        presentation.coverageLabel,
        systemImage: presentation.coverageIsWarning ? "exclamationmark.circle" : "checkmark.circle"
      )
      .help(presentation.coverageHelp)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }
}

private struct AnalyticsExportControls: View {
  let export: UsageExport
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button(L10n.string("Export CSV…")) { save(.csv) }
        Button(L10n.string("Export JSON…")) { save(.json) }
      }
      .disabled(export.days.isEmpty)
      Text(L10n.string("Includes every recorded day (\(export.days.count)), kept even after the CLI deletes old logs."))
        .font(.caption)
        .foregroundStyle(.secondary)
      if let error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private func save(_ format: UsageExport.Format) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "quotari-\(export.provider.rawValue)-usage.\(format.rawValue)"
    panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try export.data(format, exportedAt: Date()).write(to: url, options: .atomic)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}
