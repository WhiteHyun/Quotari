import Foundation
import QuotariSharedSnapshot
import Testing

struct SharedUsageSnapshotFileTests {
  private let file = SharedUsageSnapshotFile(
    url: FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-snapshot-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("UsageSnapshot.json")
  )

  @Test func aWrittenSnapshotReadsBackWithItsVersionAndISODates() throws {
    defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
    let snapshot = SharedUsageSnapshot(
      generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      providers: [SharedUsageSnapshotFixture.claude(updatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
    )

    try file.write(snapshot)

    #expect(file.read() == .snapshot(snapshot))
    let raw = try String(contentsOf: file.url, encoding: .utf8)
    #expect(raw.contains(#""schemaVersion" : 1"#))
    #expect(raw.contains(#""generatedAt" : "2027-01-15T08:00:00Z""#))
  }

  @Test func aMissingFileAGarbledFileAndANewerVersionAreTold() throws {
    defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
    #expect(file.read() == .missing)

    try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: file.url)
    #expect(file.read() == .unreadable)

    // A newer schema may reshape everything but the version.
    try Data(#"{"schemaVersion": 2, "accounts": []}"#.utf8).write(to: file.url)
    #expect(file.read() == .newerVersion(2))
  }
}

enum SharedUsageSnapshotFixture {
  static func claude(updatedAt: Date) -> SharedUsageSnapshot.Provider {
    SharedUsageSnapshot.Provider(
      id: "claude",
      name: "Claude",
      plan: "Max 20x",
      updatedAt: updatedAt,
      windows: [
        .init(
          kind: "session",
          usedPercent: 42,
          resetsAt: updatedAt.addingTimeInterval(3 * 3600 + 42 * 60),
          durationSeconds: 5 * 3600
        ),
        .init(
          kind: "weekly",
          usedPercent: 18.4,
          resetsAt: updatedAt.addingTimeInterval(3 * 86400),
          durationSeconds: 7 * 86400
        ),
        .init(kind: "custom", label: "Opus", usedPercent: 10),
      ]
    )
  }

  static func codex(updatedAt: Date) -> SharedUsageSnapshot.Provider {
    SharedUsageSnapshot.Provider(
      id: "codex",
      name: "Codex",
      plan: nil,
      updatedAt: updatedAt,
      windows: [
        .init(kind: "session", usedPercent: 10, durationSeconds: 5 * 3600),
        .init(kind: "weekly", usedPercent: 33, durationSeconds: 7 * 86400),
      ]
    )
  }
}
