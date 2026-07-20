import Foundation

public extension UsageProvider {
  var statusPageURL: URL {
    switch self {
    case .codex: URL(string: "https://status.openai.com/")!
    case .claude: URL(string: "https://status.claude.com/")!
    }
  }
}

public enum ProviderServiceState: Int, Sendable, Equatable, Comparable {
  case unknown = -1
  case operational = 0
  case degradedPerformance = 1
  case partialOutage = 2
  case majorOutage = 3

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct ProviderStatusIncident: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let status: String
  public let impact: String
  public let url: URL

  public init(id: String, name: String, status: String, impact: String, url: URL) {
    self.id = id
    self.name = name
    self.status = status
    self.impact = impact
    self.url = url
  }
}

public struct ProviderServiceStatus: Sendable, Equatable {
  public let provider: UsageProvider
  public let state: ProviderServiceState
  public let updatedAt: Date
  public let statusPageURL: URL
  public let incident: ProviderStatusIncident?

  public init(
    provider: UsageProvider,
    state: ProviderServiceState,
    updatedAt: Date,
    statusPageURL: URL,
    incident: ProviderStatusIncident? = nil
  ) {
    self.provider = provider
    self.state = state
    self.updatedAt = updatedAt
    self.statusPageURL = statusPageURL
    self.incident = incident
  }
}

public protocol ProviderStatusServing: Sendable {
  func status(for provider: UsageProvider, forceRefresh: Bool) async throws -> ProviderServiceStatus
}

public actor ProviderStatusService: ProviderStatusServing {
  public static let shared = ProviderStatusService()

  private struct CacheEntry: Sendable {
    let status: ProviderServiceStatus
    let fetchedAt: Date
  }

  private let transport: any ProviderHTTPTransport
  private let cacheLifetime: TimeInterval
  private var cache: [UsageProvider: CacheEntry] = [:]
  private var inFlight: [UsageProvider: Task<ProviderServiceStatus, Error>] = [:]

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    cacheLifetime: TimeInterval = 5 * 60
  ) {
    self.transport = transport
    self.cacheLifetime = cacheLifetime
  }

  public func status(
    for provider: UsageProvider,
    forceRefresh: Bool = false
  ) async throws -> ProviderServiceStatus {
    let now = Date()
    if !forceRefresh,
       let cached = cache[provider],
       now.timeIntervalSince(cached.fetchedAt) < cacheLifetime {
      return cached.status
    }
    if let pending = inFlight[provider] {
      return try await pending.value
    }

    let transport = transport
    let task = Task {
      try await Self.fetch(provider: provider, transport: transport, now: now)
    }
    inFlight[provider] = task
    defer { inFlight[provider] = nil }

    let result = try await task.value
    cache[provider] = CacheEntry(status: result, fetchedAt: now)
    return result
  }

  private static func fetch(
    provider: UsageProvider,
    transport: any ProviderHTTPTransport,
    now: Date
  ) async throws -> ProviderServiceStatus {
    let configuration = configuration(for: provider)
    var request = URLRequest(url: configuration.endpoint)
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await transport.data(for: request)
    guard 200 ..< 300 ~= response.statusCode else {
      throw ProviderHTTPError.status(response.statusCode)
    }

    let payload = try JSONDecoder().decode(StatusPagePayload.self, from: data)
    let relevantComponents = payload.components.filter { configuration.matches(component: $0.name) }
    let componentIDs = Set(relevantComponents.map(\.id))
    let componentState = relevantComponents.map { serviceState(componentStatus: $0.status) }.max() ?? .unknown

    var incidents = payload.incidents.filter {
      $0.components.contains(where: { componentIDs.contains($0.id) })
        || configuration.matches(incidentText: $0.searchableText)
    }
    if incidents.isEmpty, componentState > .operational {
      incidents = payload.incidents
    }
    let primaryIncident = incidents.max { impactState($0.impact) < impactState($1.impact) }
    let resolvedState = max(componentState, primaryIncident.map { impactState($0.impact) } ?? .unknown)

    return ProviderServiceStatus(
      provider: provider,
      state: resolvedState,
      updatedAt: parseDate(payload.page.updatedAt) ?? now,
      statusPageURL: configuration.statusPage,
      incident: primaryIncident.map {
        ProviderStatusIncident(
          id: $0.id,
          name: $0.name,
          status: $0.status,
          impact: $0.impact,
          url: $0.shortlink.flatMap(URL.init(string:))
            ?? configuration.statusPage.appending(path: "incidents/\($0.id)")
        )
      }
    )
  }

  private static func serviceState(componentStatus: String) -> ProviderServiceState {
    switch componentStatus {
    case "operational": .operational
    case "degraded_performance", "under_maintenance": .degradedPerformance
    case "partial_outage": .partialOutage
    case "major_outage": .majorOutage
    default: .unknown
    }
  }

  private static func impactState(_ impact: String) -> ProviderServiceState {
    switch impact {
    case "none": .operational
    case "minor": .degradedPerformance
    case "major": .partialOutage
    case "critical": .majorOutage
    default: .unknown
    }
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func configuration(for provider: UsageProvider) -> StatusConfiguration {
    switch provider {
    case .codex:
      StatusConfiguration(
        endpoint: URL(string: "https://status.openai.com/api/v2/summary.json")!,
        statusPage: provider.statusPageURL,
        componentTerms: ["codex"],
        incidentTerms: ["codex"]
      )
    case .claude:
      StatusConfiguration(
        endpoint: URL(string: "https://status.claude.com/api/v2/summary.json")!,
        statusPage: provider.statusPageURL,
        componentTerms: ["claude code", "claude api"],
        incidentTerms: ["claude code", "claude api", "api.anthropic.com"]
      )
    }
  }
}

private struct StatusConfiguration: Sendable {
  let endpoint: URL
  let statusPage: URL
  let componentTerms: [String]
  let incidentTerms: [String]

  func matches(component name: String) -> Bool {
    let name = name.lowercased()
    return componentTerms.contains { name.contains($0) }
  }

  func matches(incidentText: String) -> Bool {
    let text = incidentText.lowercased()
    return incidentTerms.contains { text.contains($0) }
  }
}

private struct StatusPage: Decodable {
  let updatedAt: String

  private enum CodingKeys: String, CodingKey {
    case updatedAt = "updated_at"
  }
}

private struct StatusPageComponent: Decodable {
  let id: String
  let name: String
  let status: String
}

private struct StatusPageIncidentUpdate: Decodable {
  let body: String
}

private struct StatusPageIncident: Decodable {
  let id: String
  let name: String
  let status: String
  let impact: String
  let shortlink: String?
  let components: [StatusPageComponent]
  let incidentUpdates: [StatusPageIncidentUpdate]

  var searchableText: String {
    ([name] + incidentUpdates.map(\.body)).joined(separator: " ")
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, status, impact, shortlink, components
    case incidentUpdates = "incident_updates"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    status = try container.decode(String.self, forKey: .status)
    impact = try container.decode(String.self, forKey: .impact)
    shortlink = try container.decodeIfPresent(String.self, forKey: .shortlink)
    components = try container.decodeIfPresent([StatusPageComponent].self, forKey: .components) ?? []
    incidentUpdates = try container.decodeIfPresent([StatusPageIncidentUpdate].self, forKey: .incidentUpdates) ?? []
  }
}

private struct StatusPagePayload: Decodable {
  let page: StatusPage
  let components: [StatusPageComponent]
  let incidents: [StatusPageIncident]
}
