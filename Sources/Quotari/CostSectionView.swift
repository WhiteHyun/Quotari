import Charts
import QuotariCore
import SwiftUI

/// The cost block: a Today / 30-day spend + tokens grid, top model, and a
/// 30-day spend bar chart. Accent-colored to match the provider.
struct CostSectionView: View {
  let cost: CostSummary
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      grid
      if !cost.daily.isEmpty {
        chart
      }
      if let model = cost.topModel {
        Text("Top model: \(model)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("Estimated from local logs")
        .font(.caption2).foregroundStyle(.tertiary)
    }
  }

  private var grid: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
      GridRow {
        metric("Today", UsageFormatter.currency(cost.todaySpend, code: cost.currencyCode))
        metric("30d cost", UsageFormatter.currency(cost.monthSpend, code: cost.currencyCode))
      }
      GridRow {
        metric("30d tokens", UsageFormatter.tokens(cost.monthTokens))
        metric("Latest tokens", UsageFormatter.tokens(cost.latestTokens))
      }
    }
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.callout.weight(.semibold).monospacedDigit())
    }
  }

  private var chart: some View {
    Chart(cost.daily) { day in
      BarMark(
        x: .value("Day", day.date, unit: .day),
        y: .value("Spend", day.spend)
      )
      .foregroundStyle(Theme.accent(accent, intensity: cost.peakSpend > 0 ? day.spend / cost.peakSpend : 0))
      .cornerRadius(1)
    }
    .chartYAxis(.hidden)
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: 10)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
          .font(.caption2)
      }
    }
    .frame(height: 56)
  }
}
