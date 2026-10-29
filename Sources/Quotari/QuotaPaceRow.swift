import QuotariCore
import SwiftUI

/// The pace trend and run-out projection under a quota window.
struct QuotaPaceRow: View {
  let pace: UsagePace

  var body: some View {
    if LocalizedUsageFormatter.paceTrend(pace) != nil || pace.runsOutIn != nil {
      HStack(spacing: 6) {
        if let trend = LocalizedUsageFormatter.paceTrend(pace) {
          Text(trend)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        Text(LocalizedUsageFormatter.paceProjection(pace))
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}
