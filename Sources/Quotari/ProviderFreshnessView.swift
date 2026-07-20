import Foundation
import SwiftUI

struct ProviderFreshness: Equatable {
  let updatedAt: Date
  let now: Date
  let refreshInterval: TimeInterval

  var isStale: Bool {
    now.timeIntervalSince(updatedAt) > refreshInterval * 2
  }

  var updatedText: String {
    let elapsed = max(0, now.timeIntervalSince(updatedAt))
    switch elapsed {
    case ..<60:
      return "Updated just now"
    case ..<3600:
      return "Updated \(Int(elapsed / 60))m ago"
    case ..<86400:
      return "Updated \(Int(elapsed / 3600))h ago"
    default:
      return "Updated \(Int(elapsed / 86400))d ago"
    }
  }

  func accessibilityText(sourceLabel: String?) -> String {
    let freshness = isStale ? "Stale, \(updatedText.lowercased())" : updatedText
    guard let sourceLabel else { return freshness }
    return "\(sourceLabel), \(freshness)"
  }
}

struct ProviderFreshnessView: View {
  let updatedAt: Date
  let refreshInterval: TimeInterval
  let sourceLabel: String?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let freshness = ProviderFreshness(
        updatedAt: updatedAt,
        now: context.date,
        refreshInterval: refreshInterval
      )

      HStack(spacing: 4) {
        if let sourceLabel {
          Text(sourceLabel)
          Text("·")
        }
        if freshness.isStale {
          Text("Stale")
            .foregroundStyle(.orange)
          Text("·")
        }
        Text(freshness.updatedText)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(freshness.accessibilityText(sourceLabel: sourceLabel))
      .help(helpText)
    }
  }

  private var helpText: String {
    var lines = ["Updated \(updatedAt.formatted(date: .abbreviated, time: .standard))"]
    if let sourceLabel {
      lines.append("Source: \(sourceLabel)")
    }
    return lines.joined(separator: "\n")
  }
}
