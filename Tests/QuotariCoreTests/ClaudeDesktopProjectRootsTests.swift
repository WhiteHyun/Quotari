import Foundation
@testable import QuotariCore
import Testing

struct ClaudeDesktopProjectRootsTests {
  @Test func locatedRootsAreReusedWithinTheLifetimeAndRefreshedAfterIt() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-desktop-roots-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = try #require(ClaudeDesktopProjectRoots.sessionRoots(homeDirectory: home).first)
    let first = sessions.appendingPathComponent("a/.claude/projects", isDirectory: true)
    let second = sessions.appendingPathComponent("b/.claude/projects", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    let now = Date()

    let initial = ClaudeDesktopProjectRoots.locate(homeDirectory: home, now: now)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let cached = ClaudeDesktopProjectRoots.locate(homeDirectory: home, now: now.addingTimeInterval(1))
    let refreshed = ClaudeDesktopProjectRoots.locate(
      homeDirectory: home,
      now: now.addingTimeInterval(ClaudeDesktopProjectRoots.cacheLifetime + 1)
    )

    #expect(initial.count == 1)
    #expect(cached.count == 1)
    #expect(refreshed.count == 2)
  }
}
