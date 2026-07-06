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
    public var label: String?

    public init(
        kind: UsageWindowKind,
        usedPercent: Double,
        resetsAt: Date? = nil,
        label: String? = nil)
    {
        self.kind = kind
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.label = label
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: UsageProvider
    public var primary: RateWindow?
    public var secondary: RateWindow?
    public var updatedAt: Date

    public init(
        provider: UsageProvider,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        updatedAt: Date)
    {
        self.provider = provider
        self.primary = primary
        self.secondary = secondary
        self.updatedAt = updatedAt
    }

    public var highestUsedPercent: Double {
        [primary?.usedPercent, secondary?.usedPercent].compactMap { $0 }.max() ?? 0
    }
}
