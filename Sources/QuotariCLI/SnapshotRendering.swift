import Foundation
import QuotariSharedSnapshot

/// Plain-text views of the shared snapshot. Remaining quota, like the menu bar.
enum SnapshotRendering {
  /// Older readings are marked with their age. Adaptive refresh waits up to
  /// half an hour while idle, so an hour means Quotari missed a refresh.
  static let staleAfter: TimeInterval = 60 * 60

  /// `Claude 5h 58% · 7d 82% left | Codex 5h 90% · 7d 67% left`
  static func statusline(_ providers: [SharedUsageSnapshot.Provider], now: Date) -> String {
    let parts = providers.compactMap { provider -> String? in
      let windows = provider.windows.filter { $0.kind == "session" || $0.kind == "weekly" }
      guard !windows.isEmpty else { return nil }
      let values = windows.map { "\(label(for: $0)) \(percent($0.remainingPercent))" }
      var part = "\(provider.name) \(values.joined(separator: " · ")) left"
      let age = now.timeIntervalSince(provider.updatedAt)
      if age >= staleAfter {
        part += " (\(duration(age)) ago)"
      }
      return part
    }
    return parts.isEmpty ? "Quotari: no data" : parts.joined(separator: " | ")
  }

  static func summary(_ providers: [SharedUsageSnapshot.Provider], now: Date) -> String {
    providers.map { provider in
      let age = now.timeIntervalSince(provider.updatedAt)
      var header = [provider.name, provider.plan].compactMap(\.self).joined(separator: " · ")
      header += age < 60 ? " · updated just now" : " · updated \(duration(age)) ago"
      if age >= staleAfter {
        header += " · stale"
      }
      let labels = provider.windows.map(label(for:))
      let width = (labels.map(\.count).max() ?? 0) + 2
      let rows = zip(labels, provider.windows).map { label, window in
        var row = "  " + label.padding(toLength: width, withPad: " ", startingAt: 0)
          + percent(window.remainingPercent).leftPadded(to: 4) + " left"
        if let resetsAt = window.resetsAt {
          let remaining = resetsAt.timeIntervalSince(now)
          row += remaining > 0 ? "  resets in \(duration(remaining))" : "  reset since this reading"
        }
        return row
      }
      return ([header] + rows).joined(separator: "\n") + "\n"
    }
    .joined(separator: "\n")
  }

  /// `5h` or `7d` from the window length, else the window's name.
  static func label(for window: SharedUsageSnapshot.Window) -> String {
    if let label = window.label {
      return label
    }
    if let seconds = window.durationSeconds, seconds >= 3600 {
      let hours = (seconds / 3600).rounded()
      if hours >= 24, hours.truncatingRemainder(dividingBy: 24) == 0 {
        return "\(Int(hours / 24))d"
      }
      return "\(Int(hours))h"
    }
    return window.kind == "weekly" ? "week" : window.kind
  }

  static func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
  }

  /// `<1m`, `42m`, `3h 5m`, `3h`, `2d 4h`, `2d`.
  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 {
      return "<1m"
    }
    if minutes < 60 {
      return "\(minutes)m"
    }
    let hours = minutes / 60
    if hours < 24 {
      return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
    }
    return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
  }
}

private extension String {
  func leftPadded(to width: Int) -> String {
    String(repeating: " ", count: max(0, width - count)) + self
  }
}
