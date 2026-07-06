import Foundation

/// The role of a usage window, modeled as a first-class value.
///
/// Design note: the app this is based on infers the role from a magic
/// `windowMinutes` number (300 = session, 10080 = weekly), which breaks the
/// moment a provider introduces a 6-hour or monthly window. We make the role
/// explicit so that fragility never exists here.
public enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    case session   // rolling short window (e.g. 5h)
    case weekly
    case custom
}

/// One resettable usage gauge (a percentage that refills at `resetsAt`).
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

/// Normalized usage for one provider. Providers with wildly different APIs all
/// funnel into this one shape, which the UI, CLI, and (later) widget consume.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: UsageProvider
    public var primary: RateWindow?     // session window
    public var secondary: RateWindow?   // weekly window
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

    /// Highest used% across all known windows — drives the menu-bar gauge.
    public var highestUsedPercent: Double {
        [primary?.usedPercent, secondary?.usedPercent].compactMap { $0 }.max() ?? 0
    }
}
