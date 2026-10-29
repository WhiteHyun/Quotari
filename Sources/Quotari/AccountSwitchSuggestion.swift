import Foundation
import QuotariCore

/// A saved account that could replace the active one, with its latest usage.
struct AccountSwitchCandidate {
  var account: ProviderAccount
  /// The account Quotari treats it as, so a live row and its saved copy match.
  var logicalID: String
  var usage: ProviderAccountUsage?
  var isMonitored: Bool
}

/// Picks the account to suggest when the active account runs low. Quotari only
/// suggests; it never switches on its own (ADR 0001).
enum AccountSwitchSuggestion {
  struct Criteria {
    var window: QuotaNotificationWindow
    /// Used percent at which a window counts as nearly out.
    var criticalUsedPercent: Double
    var now: Date
    /// Older readings may no longer hold, so they never back a suggestion.
    var maximumAge: TimeInterval
  }

  /// The monitored saved account with the most room in the critical window.
  /// Ties go to more room in the other window, then to list order.
  static func best(
    among candidates: [AccountSwitchCandidate],
    activeLogicalID: String,
    criteria: Criteria
  ) -> AccountSwitchCandidate? {
    let ranked = candidates.enumerated().compactMap { index, candidate in
      rank(candidate, order: index, activeLogicalID: activeLogicalID, criteria: criteria)
    }
    return ranked.min { lhs, rhs in
      if lhs.room != rhs.room {
        return lhs.room > rhs.room
      }
      if lhs.otherRoom != rhs.otherRoom {
        return lhs.otherRoom > rhs.otherRoom
      }
      return lhs.order < rhs.order
    }?.candidate
  }

  private struct Ranked {
    var candidate: AccountSwitchCandidate
    var room: Double
    var otherRoom: Double
    var order: Int
  }

  private static func rank(
    _ candidate: AccountSwitchCandidate,
    order: Int,
    activeLogicalID: String,
    criteria: Criteria
  ) -> Ranked? {
    guard candidate.isMonitored,
          candidate.account.credentialSource.isCaptured,
          candidate.logicalID != activeLogicalID,
          let usage = candidate.usage,
          usage.error == nil,
          let snapshot = usage.snapshot,
          criteria.now.timeIntervalSince(snapshot.updatedAt) <= criteria.maximumAge,
          let window = snapshot.window(criteria.window)
    else { return nil }
    let windows = [snapshot.primary, snapshot.secondary].compactMap(\.self)
    guard windows.allSatisfy({ $0.usedPercent < criteria.criticalUsedPercent }) else { return nil }
    let other = snapshot.window(criteria.window == .session ? .weekly : .session)?.remainingPercent ?? 100
    return Ranked(candidate: candidate, room: window.remainingPercent, otherRoom: other, order: order)
  }
}

private extension UsageSnapshot {
  func window(_ window: QuotaNotificationWindow) -> RateWindow? {
    switch window {
    case .session: primary
    case .weekly: secondary
    }
  }
}
