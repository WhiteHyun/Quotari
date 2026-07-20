import Foundation
@testable import QuotariCore
import Testing

struct ProviderStatusTests {
  @Test func codexIncidentRaisesAnOtherwiseOperationalComponent() async throws {
    let transport = ProviderStatusTransportStub(json: """
    {
      "page": { "updated_at": "2026-07-20T03:25:54Z" },
      "components": [
        { "id": "codex-api", "name": "Codex API", "status": "operational" }
      ],
      "incidents": [
        {
          "id": "incident-1",
          "name": "Elevated errors for Codex workflows",
          "status": "monitoring",
          "impact": "minor",
          "incident_updates": [{ "body": "Codex requests may fail." }]
        }
      ]
    }
    """)
    let service = ProviderStatusService(transport: transport)

    let status = try await service.status(for: .codex)

    #expect(status.state == .degradedPerformance)
    #expect(status.incident?.name == "Elevated errors for Codex workflows")
    #expect(status.incident?.url.absoluteString == "https://status.openai.com/incidents/incident-1")
  }

  @Test func relevantComponentAndIncidentUseTheHighestSeverity() async throws {
    let transport = ProviderStatusTransportStub(json: """
    {
      "page": { "updated_at": "2026-07-20T03:17:24.780Z" },
      "components": [
        { "id": "claude-code", "name": "Claude Code", "status": "degraded_performance" },
        { "id": "claude-api", "name": "Claude API (api.anthropic.com)", "status": "operational" }
      ],
      "incidents": [
        {
          "id": "incident-2",
          "name": "Claude Code partial outage",
          "status": "identified",
          "impact": "major",
          "shortlink": "https://status.claude.com/incidents/incident-2",
          "components": [
            { "id": "claude-code", "name": "Claude Code", "status": "partial_outage" }
          ],
          "incident_updates": []
        }
      ]
    }
    """)
    let service = ProviderStatusService(transport: transport)

    let status = try await service.status(for: .claude)

    #expect(status.state == .partialOutage)
    #expect(status.incident?.id == "incident-2")
    #expect(status.updatedAt == Date(timeIntervalSince1970: 1_784_517_444.78))
  }

  @Test func unrelatedIncidentDoesNotDegradeCodex() async throws {
    let transport = ProviderStatusTransportStub(json: """
    {
      "page": { "updated_at": "2026-07-20T03:25:54Z" },
      "components": [
        { "id": "codex-api", "name": "Codex API", "status": "operational" }
      ],
      "incidents": [
        {
          "id": "incident-3",
          "name": "ChatGPT image uploads unavailable",
          "status": "investigating",
          "impact": "critical",
          "incident_updates": []
        }
      ]
    }
    """)
    let service = ProviderStatusService(transport: transport)

    let status = try await service.status(for: .codex)

    #expect(status.state == .operational)
    #expect(status.incident == nil)
  }

  @Test func unrelatedIncidentDoesNotOverrideADegradedCodexComponent() async throws {
    let transport = ProviderStatusTransportStub(json: """
    {
      "page": { "updated_at": "2026-07-20T03:25:54Z" },
      "components": [
        { "id": "codex-api", "name": "Codex API", "status": "degraded_performance" }
      ],
      "incidents": [
        {
          "id": "incident-4",
          "name": "ChatGPT image uploads unavailable",
          "status": "investigating",
          "impact": "critical",
          "incident_updates": []
        }
      ]
    }
    """)
    let service = ProviderStatusService(transport: transport)

    let status = try await service.status(for: .codex)

    #expect(status.state == .degradedPerformance)
    #expect(status.incident == nil)
  }

  @Test func cachedStatusAvoidsRepeatedRequests() async throws {
    let transport = ProviderStatusTransportStub(json: """
    {
      "page": { "updated_at": "2026-07-20T03:25:54Z" },
      "components": [
        { "id": "codex-api", "name": "Codex API", "status": "operational" }
      ],
      "incidents": []
    }
    """)
    let service = ProviderStatusService(transport: transport)

    _ = try await service.status(for: .codex)
    _ = try await service.status(for: .codex)

    #expect(await transport.callCount == 1)
  }
}

private actor ProviderStatusTransportStub: ProviderHTTPTransport {
  let data: Data
  private(set) var callCount = 0

  init(json: String) {
    data = Data(json.utf8)
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    callCount += 1
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
  }
}
