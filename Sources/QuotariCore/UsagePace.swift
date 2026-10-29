import Foundation

/// How current consumption compares to a steady (linear) pace through a window,
/// and whether it will run out before the window resets.
public struct UsagePace: Sendable, Equatable {
  /// `usedPercent` minus the linear-expected used% at `now`.
  /// Positive = ahead of pace (deficit); negative = behind pace (reserve).
  public let deltaPercent: Double
  /// Seconds until the window would hit 100% at the current rate, if that
  /// happens before reset; `nil` means it lasts until reset.
  public let runsOutIn: TimeInterval?
  /// How much faster than the current rate you could go and still last until
  /// reset (> 1 means headroom). `nil` when not meaningful.
  public let headroomMultiplier: Double?

  public var isDeficit: Bool {
    deltaPercent > 0
  }

  public init(deltaPercent: Double, runsOutIn: TimeInterval?, headroomMultiplier: Double?) {
    self.deltaPercent = deltaPercent
    self.runsOutIn = runsOutIn
    self.headroomMultiplier = headroomMultiplier
  }

  /// Requires `resetsAt` and `duration`; returns `nil` when pace can't be derived.
  /// `recentBurnRate` (percent per wall-clock second, from quota history)
  /// replaces the window average for run-out and headroom. Weekday-only pace
  /// applies to weekly windows and leaves weekends out of elapsed and
  /// remaining time.
  public static func compute(
    window: RateWindow,
    now: Date,
    recentBurnRate: Double? = nil,
    countsWeekdaysOnly: Bool = false,
    calendar: Calendar = .current
  ) -> UsagePace? {
    guard let resetsAt = window.resetsAt,
          let duration = window.duration, duration > 0
    else { return nil }

    let timeUntilReset = resetsAt.timeIntervalSince(now)
    guard timeUntilReset > 0 else { return nil }

    let clock = PaceClock(weekdaysOnly: countsWeekdaysOnly && window.kind == .weekly, calendar: calendar)
    let start = resetsAt.addingTimeInterval(-duration)
    let total = clock.seconds(from: start, to: resetsAt)
    let elapsed = min(max(clock.seconds(from: start, to: now), 0), total)
    guard total > 0, elapsed > 0 else {
      return UsagePace(deltaPercent: 0, runsOutIn: nil, headroomMultiplier: nil)
    }

    let used = min(max(window.usedPercent, 0), 100)
    let delta = used - elapsed / total * 100
    let remaining = 100 - used

    if let recentBurnRate {
      return UsagePace(
        deltaPercent: delta,
        runsOutIn: recentBurnRate > 0 && remaining / recentBurnRate < timeUntilReset
          ? remaining / recentBurnRate
          : nil,
        headroomMultiplier: recentBurnRate > 0 ? remaining / (recentBurnRate * timeUntilReset) : nil
      )
    }

    let rate = used / elapsed
    let remainingTime = clock.seconds(from: now, to: resetsAt)
    guard rate > 0 else {
      return UsagePace(deltaPercent: delta, runsOutIn: nil, headroomMultiplier: nil)
    }
    let eta = remaining / rate
    let projectedRemainingUse = rate * remainingTime
    return UsagePace(
      deltaPercent: delta,
      runsOutIn: eta < remainingTime ? clock.wallInterval(from: now, covering: eta) : nil,
      headroomMultiplier: projectedRemainingUse > 0 ? remaining / projectedRemainingUse : nil
    )
  }
}

/// Measures time either on the wall clock or on weekdays only.
private struct PaceClock {
  let weekdaysOnly: Bool
  let calendar: Calendar

  func seconds(from start: Date, to end: Date) -> TimeInterval {
    guard weekdaysOnly else { return end.timeIntervalSince(start) }
    var total: TimeInterval = 0
    var cursor = start
    while cursor < end {
      let next = min(nextDay(after: cursor), end)
      if !calendar.isDateInWeekend(cursor) {
        total += next.timeIntervalSince(cursor)
      }
      cursor = next
    }
    return total
  }

  /// The wall-clock time from `start` until `seconds` of counted time pass.
  func wallInterval(from start: Date, covering seconds: TimeInterval) -> TimeInterval {
    guard weekdaysOnly else { return seconds }
    var remaining = seconds
    var cursor = start
    while remaining > 0 {
      let next = nextDay(after: cursor)
      if !calendar.isDateInWeekend(cursor) {
        let available = next.timeIntervalSince(cursor)
        if remaining <= available {
          return cursor.addingTimeInterval(remaining).timeIntervalSince(start)
        }
        remaining -= available
      }
      cursor = next
    }
    return cursor.timeIntervalSince(start)
  }

  private func nextDay(after date: Date) -> Date {
    let startOfDay = calendar.startOfDay(for: date)
    return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(86400)
  }
}
