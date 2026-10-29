import Foundation

/// A provider service problem the user should know about.
public struct ProviderOutage: Equatable, Sendable {
  public var incidentID: String?
  public var title: String

  public init(incidentID: String?, title: String) {
    self.incidentID = incidentID
    self.title = title
  }
}

public enum ProviderOutageEvent: Equatable, Sendable {
  case started(provider: UsageProvider, title: String)
  case resolved(provider: UsageProvider, title: String)
}

/// Turns successive status-page readings into outage start and resolution events.
public struct ProviderOutageTracker: Equatable, Sendable {
  public private(set) var outages: [UsageProvider: ProviderOutage] = [:]

  public init() {}

  public func outage(for provider: UsageProvider) -> ProviderOutage? {
    outages[provider]
  }

  /// Drops a provider that is no longer watched, without reporting a resolution.
  public mutating func forget(_ provider: UsageProvider) {
    outages[provider] = nil
  }

  public mutating func update(with status: ProviderServiceStatus) -> ProviderOutageEvent? {
    let provider = status.provider
    let previous = outages[provider]
    let current = Self.outage(in: status)
    outages[provider] = current

    switch (previous, current) {
    case let (nil, current?):
      return .started(provider: provider, title: current.title)
    case let (previous?, nil):
      return .resolved(provider: provider, title: previous.title)
    case let (previous?, current?) where previous.incidentID != current.incidentID:
      return .started(provider: provider, title: current.title)
    default:
      return nil
    }
  }

  /// An open incident, or components down without one. Degraded performance
  /// alone is not an outage.
  private static func outage(in status: ProviderServiceStatus) -> ProviderOutage? {
    if let incident = status.incident {
      return ProviderOutage(incidentID: incident.id, title: incident.name)
    }
    let down = status.components.filter { $0.state >= .partialOutage }.map(\.name)
    guard !down.isEmpty else { return nil }
    return ProviderOutage(incidentID: nil, title: down.joined(separator: ", "))
  }
}
