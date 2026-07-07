import Foundation

public enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
  case session
  case weekly
  case custom
}

public struct RateWindow: Codable, Equatable, Sendable {
  public var kind: UsageWindowKind
  public var usedPercent: Double
  public var resetsAt: Date?
  /// Total window length; enables pace/projection math.
  public var duration: TimeInterval?
  public var label: String?

  public init(
    kind: UsageWindowKind,
    usedPercent: Double,
    resetsAt: Date? = nil,
    duration: TimeInterval? = nil,
    label: String? = nil
  ) {
    self.kind = kind
    self.usedPercent = min(100, max(0, usedPercent))
    self.resetsAt = resetsAt
    self.duration = duration
    self.label = label
  }

  public var remainingPercent: Double {
    max(0, 100 - usedPercent)
  }
}

/// A provider-specific named limit beyond session/weekly (e.g. "Codex Spark",
/// "Daily Routines").
public struct NamedWindow: Codable, Equatable, Sendable, Identifiable {
  public var title: String
  public var window: RateWindow
  public var id: String {
    title
  }

  public init(title: String, window: RateWindow) {
    self.title = title
    self.window = window
  }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
  public var provider: UsageProvider
  public var plan: String?
  public var account: String?
  public var primary: RateWindow? // session window
  public var secondary: RateWindow? // weekly window
  public var extraWindows: [NamedWindow]
  public var cost: CostSummary?
  public var updatedAt: Date

  public init(
    provider: UsageProvider,
    plan: String? = nil,
    account: String? = nil,
    primary: RateWindow? = nil,
    secondary: RateWindow? = nil,
    extraWindows: [NamedWindow] = [],
    cost: CostSummary? = nil,
    updatedAt: Date
  ) {
    self.provider = provider
    self.plan = plan
    self.account = account
    self.primary = primary
    self.secondary = secondary
    self.extraWindows = extraWindows
    self.cost = cost
    self.updatedAt = updatedAt
  }

  /// Highest used% across the primary/secondary windows — drives the menu-bar
  /// gauge. Extra named windows are excluded so a minor limit can't dominate.
  public var highestUsedPercent: Double {
    [primary?.usedPercent, secondary?.usedPercent].compactMap(\.self).max() ?? 0
  }
}
