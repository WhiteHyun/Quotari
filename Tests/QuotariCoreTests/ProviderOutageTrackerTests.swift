import Foundation
@testable import QuotariCore
import Testing

struct ProviderOutageTrackerTests {
  @Test func anIncidentStartsAnOutage() async throws {
    var tracker = ProviderOutageTracker()
    _ = try await tracker.update(with: status(operationalJSON))

    let event = try await tracker.update(with: status(incidentJSON(id: "incident-1", status: "investigating")))

    #expect(event == .started(provider: .codex, title: "Elevated errors for Codex workflows"))
    #expect(tracker.outage(for: .codex)?.title == "Elevated errors for Codex workflows")
  }

  @Test func updatesToTheSameIncidentStayQuiet() async throws {
    var tracker = ProviderOutageTracker()
    _ = try await tracker.update(with: status(incidentJSON(id: "incident-1", status: "investigating")))

    let event = try await tracker.update(with: status(incidentJSON(id: "incident-1", status: "monitoring")))

    #expect(event == nil)
    #expect(tracker.outage(for: .codex) != nil)
  }

  @Test func clearingTheIncidentResolvesTheOutage() async throws {
    var tracker = ProviderOutageTracker()
    _ = try await tracker.update(with: status(incidentJSON(id: "incident-1", status: "monitoring")))

    let event = try await tracker.update(with: status(operationalJSON))

    #expect(event == .resolved(provider: .codex, title: "Elevated errors for Codex workflows"))
    #expect(tracker.outage(for: .codex) == nil)
  }

  @Test func aComponentOutageWithoutAnIncidentStillCounts() async throws {
    var tracker = ProviderOutageTracker()

    let event = try await tracker.update(with: status("""
    {
      "page": { "updated_at": "2027-01-15T08:10:00Z" },
      "components": [ { "id": "codex-api", "name": "Codex API", "status": "major_outage" } ]
    }
    """))

    #expect(event == .started(provider: .codex, title: "Codex API"))
  }

  @Test func forgettingAProviderDropsItsOutageQuietly() async throws {
    var tracker = ProviderOutageTracker()
    _ = try await tracker.update(with: status(incidentJSON(id: "incident-1", status: "investigating")))

    tracker.forget(.codex)

    #expect(tracker.outage(for: .codex) == nil)
    #expect(try await tracker.update(with: status(operationalJSON)) == nil)
  }
}

// MARK: - Recorded status payloads (synthetic values in the observed shape)

private let operationalJSON = """
{
  "page": { "updated_at": "2027-01-15T08:00:00Z" },
  "status": { "description": "All Systems Operational", "indicator": "none" },
  "components": [ { "id": "codex-api", "name": "Codex API", "status": "operational" } ]
}
"""

private func incidentJSON(id: String, status: String, name: String = "Elevated errors for Codex workflows") -> String {
  """
  {
    "page": { "updated_at": "2027-01-15T08:05:00Z" },
    "components": [ { "id": "codex-api", "name": "Codex API", "status": "degraded_performance" } ],
    "incidents": [
      { "id": "\(id)", "name": "\(name)", "status": "\(status)", "impact": "minor",
        "incident_updates": [{ "body": "Codex requests may fail." }] }
    ]
  }
  """
}

private func status(_ json: String) async throws -> ProviderServiceStatus {
  try await ProviderStatusService(transport: RecordedStatusTransport(json: json)).status(for: .codex)
}

private struct RecordedStatusTransport: ProviderHTTPTransport {
  let json: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    return (Data(json.utf8), response)
  }
}
