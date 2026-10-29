import Foundation
import QuotariCore

/// Pure rules for the quota value shown beside the menu-bar mascot.
enum MenuBarQuotaDisplay {
  static func usedPercent(in snapshot: UsageSnapshot, window: MenuBarQuotaWindow) -> Double? {
    switch window {
    case .session:
      snapshot.primary?.usedPercent
    case .weekly:
      snapshot.secondary?.usedPercent
    case .automatic:
      // Named extras count only when no standard window exists, so a minor
      // limit can't outweigh the plan's own session or weekly quota.
      [snapshot.primary?.usedPercent, snapshot.secondary?.usedPercent]
        .compactMap(\.self)
        .max()
        ?? snapshot.extraWindows.map(\.window.usedPercent).max()
    }
  }

  /// Used values carry an arrow so they can't be mistaken for remaining quota.
  static func text(usedPercent: Double, presentation: MenuBarQuotaPresentation) -> String {
    switch presentation {
    case .remaining:
      "\(Int((100 - usedPercent).rounded()))%"
    case .used:
      "↑\(Int(usedPercent.rounded()))%"
    }
  }
}
