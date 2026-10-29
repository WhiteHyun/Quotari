import Charts
import QuotariCore
import SwiftUI

/// The current window's recorded usage across the whole window, so the line
/// shows where in the cycle it was used. Gaps in the history stay gaps.
struct QuotaBurndownSparkline: View {
  let readings: [QuotaObservation]
  let window: RateWindow
  let accent: Color

  private var timeDomain: ClosedRange<Date>? {
    guard let resetsAt = window.resetsAt, let duration = window.duration, duration > 0 else { return nil }
    return resetsAt.addingTimeInterval(-duration) ... resetsAt
  }

  var body: some View {
    if readings.count >= 2 {
      Chart {
        ForEach(Array(QuotaBurndown.segments(readings).enumerated()), id: \.offset) { index, segment in
          ForEach(segment, id: \.observedAt) { reading in
            LineMark(
              x: .value("Time", reading.observedAt),
              y: .value("Used", reading.usedPercent),
              series: .value("Segment", index)
            )
            .foregroundStyle(accent)
            .interpolationMethod(.monotone)
          }
        }
      }
      .chartYScale(domain: 0 ... 100)
      .chartXScale(domain: timeDomain ?? readings[0].observedAt ... readings[readings.count - 1].observedAt)
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .frame(height: 16)
      .accessibilityHidden(true)
    }
  }
}
