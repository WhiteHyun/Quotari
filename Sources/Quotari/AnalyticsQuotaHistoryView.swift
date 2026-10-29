import Charts
import QuotariCore
import SwiftUI

/// The dashboard account's recorded quota readings over the retained days.
/// Gaps stay gaps; a reset shows as the drop it was.
struct AnalyticsQuotaHistoryView: View {
  @Environment(UsageStore.self) private var store
  let provider: UsageProvider
  let accent: Color

  var body: some View {
    let series = [
      (L10n.string("Session"), store.quotaHistoryObservations(for: provider, kind: .session)),
      (L10n.string("Weekly"), store.quotaHistoryObservations(for: provider, kind: .weekly)),
    ].filter { $0.1.count >= 2 }
    if !series.isEmpty {
      AnalyticsSection(L10n.string("Quota history")) {
        ForEach(series, id: \.0) { title, readings in
          VStack(alignment: .leading, spacing: 8) {
            Text(title)
              .font(.subheadline)
              .foregroundStyle(.secondary)
            chart(readings)
          }
        }
      }
    }
  }

  private func chart(_ readings: [QuotaObservation]) -> some View {
    Chart {
      ForEach(Array(QuotaBurndown.segments(readings).enumerated()), id: \.offset) { index, segment in
        ForEach(segment, id: \.observedAt) { reading in
          LineMark(
            x: .value(L10n.string("Time"), reading.observedAt),
            y: .value(L10n.string("Used"), reading.usedPercent),
            series: .value("Segment", index)
          )
          .foregroundStyle(accent)
        }
      }
    }
    .chartYScale(domain: 0 ... 100)
    .chartYAxis {
      AxisMarks(position: .leading, values: [0, 50, 100]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let percent = value.as(Int.self) {
            Text("\(percent)%").font(.caption2)
          }
        }
      }
    }
    .frame(height: 120)
    .accessibilityLabel(L10n.string("Quota used over time"))
  }
}
