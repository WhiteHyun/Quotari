import SwiftUI

struct QuotaBarView: View {
  let remainingPercent: Double
  let thresholds: QuotaBarThresholds?
  let accent: Color

  var body: some View {
    GeometryReader { geometry in
      let fraction = min(1, max(0, remainingPercent / 100))
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Theme.usageTrack)
          .frame(height: 5)
        if let thresholds {
          riskZoneFill(
            thresholds: thresholds,
            trackWidth: geometry.size.width,
            fraction: fraction
          )
        } else {
          Capsule()
            .fill(accent)
            .frame(height: 5)
            .frame(width: max(fraction > 0 ? 4 : 0, geometry.size.width * fraction))
            .animation(.easeOut(duration: 0.4), value: fraction)
        }
      }
    }
    .frame(height: 5)
  }

  @ViewBuilder
  private func riskZoneFill(
    thresholds: QuotaBarThresholds,
    trackWidth: CGFloat,
    fraction: Double
  ) -> some View {
    let fillWidth = trackWidth * fraction
    if fraction > 0, fillWidth < 4 {
      Capsule()
        .fill(Theme.quotaCritical)
        .frame(width: 4, height: 5)
    } else {
      let segments = thresholds.segments(forRemainingPercent: remainingPercent)
      HStack(spacing: 0) {
        Rectangle()
          .fill(Theme.quotaCritical)
          .frame(width: trackWidth * segments.criticalFraction)
        Rectangle()
          .fill(Theme.quotaWarning)
          .frame(width: trackWidth * segments.warningFraction)
        Rectangle()
          .fill(accent)
          .frame(width: trackWidth * segments.providerFraction)
      }
      .frame(width: fillWidth, height: 5, alignment: .leading)
      .clipShape(Capsule())
      .animation(.easeOut(duration: 0.4), value: fraction)
    }
  }
}
