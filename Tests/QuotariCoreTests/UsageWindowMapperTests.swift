import Foundation
@testable import QuotariCore
import Testing

/// A canonical raw payload shape used by the contract fixtures: a lossy list
/// of windows with leniently-typed fields, decoded the way real provider
/// strategies are expected to decode.
private struct Payload: Decodable {
  let windows: LossyArray<WindowEntry>
}

private struct WindowEntry: Decodable {
  let key: String
  let usedPercent: LenientDouble?
  let remainingPercent: LenientDouble?
  let resetsAt: LenientDate?
  let label: String?

  enum CodingKeys: String, CodingKey {
    case key
    case usedPercent = "used_percent"
    case remainingPercent = "remaining_percent"
    case resetsAt = "resets_at"
    case label
  }

  var raw: RawUsageWindow {
    RawUsageWindow(
      key: key,
      usedPercent: usedPercent?.value,
      remainingPercent: remainingPercent?.value,
      resetsAt: resetsAt?.value,
      label: label
    )
  }
}

private func loadFixture(_ name: String) throws -> UsageWindowMapper.Mapped {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/\(name).json")
  let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
  return UsageWindowMapper.map(payload.windows.elements.map(\.raw))
}

struct UsageWindowContractTests {
  @Test func standardPayloadMapsSessionWeeklyAndExtras() throws {
    let mapped = try loadFixture("usage-standard")
    #expect(mapped.primary?.usedPercent == 27)
    #expect(mapped.primary?.resetsAt != nil)
    #expect(mapped.primary?.duration == TimeInterval(5 * 3600)) // inferred from "five_hour"
    #expect(mapped.secondary?.usedPercent == 34)
    #expect(mapped.secondary?.duration == TimeInterval(7 * 24 * 3600))
    #expect(mapped.extraWindows.map(\.title) == ["Opus", "Daily Routines"])
    #expect(mapped.extraWindows[1].window.usedPercent == 0) // from remaining 100
  }

  /// The policy-change scenario: a provider replaces one model-only window
  /// with another. The new key must surface without any app update.
  @Test func renamedModelWindowSurvivesWithoutMappingChanges() throws {
    let mapped = try loadFixture("usage-policy-change")
    #expect(mapped.secondary?.usedPercent == 76)
    #expect(mapped.extraWindows.map(\.title) == ["Fable only", "Haiku"])
    #expect(mapped.extraWindows[0].window.usedPercent == 100)
  }

  @Test func malformedEntriesAreDroppedNotFatal() throws {
    let mapped = try loadFixture("usage-malformed")
    #expect(mapped.primary?.usedPercent == 73) // "73" as a string
    #expect(mapped.secondary?.usedPercent == 0) // boolean percent → unknown → 0
    #expect(mapped.secondary?.resetsAt != nil) // ISO 8601 string parsed
    #expect(mapped.extraWindows.isEmpty) // entry with a non-string key dropped
  }
}

struct UsageWindowMapperUnitTests {
  @Test func humanizedTitles() {
    #expect(UsageWindowMapper.humanizedTitle(for: "seven_day_fable") == "Fable")
    #expect(UsageWindowMapper.humanizedTitle(for: "daily_routines") == "Daily Routines")
    #expect(UsageWindowMapper.humanizedTitle(for: "five_hour_spark") == "Spark")
    #expect(UsageWindowMapper.humanizedTitle(for: "seven-day") == "Seven Day") // nothing to strip
  }

  @Test func duplicateSessionKeysFallThroughToExtras() {
    let mapped = UsageWindowMapper.map([
      RawUsageWindow(key: "five_hour", usedPercent: 10),
      RawUsageWindow(key: "session", usedPercent: 20),
    ])
    #expect(mapped.primary?.usedPercent == 10)
    #expect(mapped.extraWindows.count == 1)
    #expect(mapped.extraWindows[0].window.usedPercent == 20)
  }

  @Test func labelBeatsHumanizedKey() {
    let mapped = UsageWindowMapper.map([
      RawUsageWindow(key: "seven_day_fable", usedPercent: 1, label: "Fable only"),
    ])
    #expect(mapped.extraWindows[0].title == "Fable only")
  }
}
