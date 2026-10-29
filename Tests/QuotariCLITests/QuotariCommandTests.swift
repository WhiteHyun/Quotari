import Foundation
@testable import QuotariCLI
import QuotariSharedSnapshot
import Testing

struct QuotariCommandTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let file = SharedUsageSnapshotFile(
    url: FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-cli-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("UsageSnapshot.json")
  )

  @Test func theStatuslineShowsRemainingQuotaPerProvider() throws {
    defer { cleanUp() }
    try write(
      SharedUsageSnapshotFixture.claude(updatedAt: now.addingTimeInterval(-120)),
      SharedUsageSnapshotFixture.codex(updatedAt: now.addingTimeInterval(-2 * 3600 - 5 * 60))
    )

    #expect(run("statusline") == .init(
      standardOutput: "Claude 5h 58% · 7d 82% left | Codex 5h 90% · 7d 67% left (2h 5m ago)\n"
    ))
    #expect(run("statusline", "--provider", "Claude").standardOutput == "Claude 5h 58% · 7d 82% left\n")
  }

  @Test func theSummaryListsEveryWindowWithItsReset() throws {
    defer { cleanUp() }
    try write(SharedUsageSnapshotFixture.claude(updatedAt: now.addingTimeInterval(-180)))

    #expect(run() == .init(standardOutput: """
    Claude · Max 20x · updated 3m ago
      5h     58% left  resets in 3h 39m
      7d     82% left  resets in 2d 23h
      Opus   90% left

    """))
  }

  @Test func jsonPrintsTheSnapshotFilteredByProvider() throws {
    defer { cleanUp() }
    let claude = SharedUsageSnapshotFixture.claude(updatedAt: now)
    try write(claude, SharedUsageSnapshotFixture.codex(updatedAt: now))

    let output = run("--json", "--provider", "claude")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let printed = try decoder.decode(SharedUsageSnapshot.self, from: Data(output.standardOutput.utf8))
    #expect(printed.providers == [claude])
    #expect(output.exitCode == 0)
  }

  @Test func aMissingOrNewerSnapshotFailsExceptInTheStatusline() throws {
    defer { cleanUp() }
    #expect(run("statusline") == .init(standardOutput: "Quotari: no data\n"))
    let missing = run("--json")
    #expect(missing.exitCode == 1)
    #expect(missing.standardOutput.isEmpty)
    #expect(missing.standardError.contains("Open Quotari"))

    try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"schemaVersion": 9}"#.utf8).write(to: file.url)
    #expect(run("statusline") == .init(standardOutput: "Quotari: update needed\n"))
    #expect(run().exitCode == 1)
    #expect(run().standardError.contains("schema version 9"))
  }

  @Test func unknownArgumentsPrintUsage() {
    let output = run("--sessions")

    #expect(output.exitCode == 2)
    #expect(output.standardError.hasPrefix("Unknown argument: --sessions"))
    #expect(output.standardError.contains("Usage: quotari"))
    #expect(run("--help") == .init(standardOutput: QuotariCommand.usage))
  }

  private func run(_ arguments: String...) -> QuotariCommand.Output {
    QuotariCommand.run(arguments, file: file, now: now)
  }

  private func write(_ providers: SharedUsageSnapshot.Provider...) throws {
    try file.write(SharedUsageSnapshot(generatedAt: now, providers: providers))
  }

  private func cleanUp() {
    try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
  }
}
