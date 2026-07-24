import Charts
import SwiftUI

struct UsageInsightsChart: View {
  let presentation: UsageInsightsPresentation
  let accent: Color

  var body: some View {
    Chart {
      ForEach(presentation.points) { point in
        if let value = point.value {
          BarMark(
            x: .value(L10n.string("Day"), point.date, unit: .day),
            y: .value(L10n.string("Usage"), value)
          )
          .foregroundStyle(barColor(value))
          .cornerRadius(2)
          .accessibilityLabel(accessibilityDate(point.date))
          .accessibilityValue(axisLabel(value))
        } else {
          PointMark(
            x: .value(L10n.string("Day"), point.date, unit: .day),
            y: .value(L10n.string("Usage"), 0)
          )
          .symbolSize(0)
          .accessibilityLabel(accessibilityDate(point.date))
          .accessibilityValue(L10n.string("Not available"))
        }
      }
      RuleMark(y: .value(L10n.string("Average"), presentation.average))
        .foregroundStyle(.secondary.opacity(0.65))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .annotation(position: .top, alignment: .trailing, spacing: 2) {
          Text(L10n.string("Avg \(presentation.averageValue)"))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
          .foregroundStyle(Color.primary.opacity(0.08))
        AxisValueLabel {
          if let value = value.as(Double.self) {
            Text(axisLabel(value))
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .stride(
        by: .day,
        count: presentation.period == .sevenDays ? 1 : 10
      )) { _ in
        AxisValueLabel(format: xAxisFormat)
          .font(.caption2)
      }
    }
    .frame(height: 96)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.string("Usage trend"))
  }

  private var xAxisFormat: Date.FormatStyle {
    if presentation.period == .sevenDays {
      return .dateTime.weekday(.abbreviated)
    }
    return .dateTime.month(.abbreviated).day()
  }

  private func barColor(_ value: Double) -> Color {
    let peak = presentation.points.compactMap(\.value).max() ?? 0
    let intensity = peak > 0 ? value / peak : 0
    return Theme.accent(accent, intensity: intensity)
  }

  private func accessibilityDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.wide).day())
  }

  private func axisLabel(_ value: Double) -> String {
    switch presentation.metric {
    case let .spend(currencyCode):
      LocalizedUsageFormatter.currency(value, code: currencyCode)
    case .tokens:
      LocalizedUsageFormatter.tokens(Int(value.rounded()))
    }
  }
}
