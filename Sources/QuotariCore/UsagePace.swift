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
  public static func compute(window: RateWindow, now: Date) -> UsagePace? {
    guard let resetsAt = window.resetsAt,
          let duration = window.duration, duration > 0
    else { return nil }

    let timeUntilReset = resetsAt.timeIntervalSince(now)
    guard timeUntilReset > 0 else { return nil }

    let elapsed = min(max(duration - timeUntilReset, 0), duration)
    guard elapsed > 0 else {
      return UsagePace(deltaPercent: 0, runsOutIn: nil, headroomMultiplier: nil)
    }

    let used = min(max(window.usedPercent, 0), 100)
    let expected = elapsed / duration * 100
    let delta = used - expected

    let ratePerSecond = used / elapsed
    let remaining = 100 - used

    var runsOutIn: TimeInterval?
    var headroom: Double?
    if ratePerSecond > 0 {
      let eta = remaining / ratePerSecond
      if eta < timeUntilReset { runsOutIn = eta }
      let projectedRemainingUse = ratePerSecond * timeUntilReset
      if projectedRemainingUse > 0 { headroom = remaining / projectedRemainingUse }
    }

    return UsagePace(deltaPercent: delta, runsOutIn: runsOutIn, headroomMultiplier: headroom)
  }
}
