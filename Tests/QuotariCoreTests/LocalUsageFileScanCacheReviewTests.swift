import Foundation
@testable import QuotariCore
import Testing

extension LocalUsageFileScanCacheTests {
  @Test func cacheHitRevalidatesDescriptorBoundSourcePath() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("first-alias.jsonl")
    let link = fixture.root.appendingPathComponent("active.jsonl")
    try FileManager.default.linkItem(at: fixture.firstUsageURL, to: alias)
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: fixture.firstUsageURL.path
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let start = try #require(
      calendar.date(byAdding: .day, value: -29, to: fixture.now)
    )
    let range = DayRange(start: start, end: fixture.now, calendar: calendar)
    let initialScanner = fixture.scanner(
      capture: FileParseCapture(),
      timeZone: calendar.timeZone
    )
    _ = initialScanner.scanFile(link, provider: .codex, range: range) {
      initialScanner.parseCodexFile(handle: $0, sourcePath: $1, range: range)
    }
    let capture = FileParseCapture()
    let scanner = fixture.scanner(
      capture: capture,
      timeZone: calendar.timeZone,
      onCacheLoaded: { _ in
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(
          atPath: link.path,
          withDestinationPath: alias.path
        )
      }
    )

    let rescanned = scanner.scanFile(link, provider: .codex, range: range) {
      scanner.parseCodexFile(handle: $0, sourcePath: $1, range: range)
    }
    let expectedSessionID = ProviderCredentialIdentity.fingerprint(
      of: alias.standardizedFileURL.path
    )

    #expect(rescanned.sessionIDs == [expectedSessionID])
    #expect(capture.paths == [link.lastPathComponent])
  }

  @Test func pruneRunsAtMostOncePerIntervalAcrossScanners() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let cache = LocalUsageFileScanCache(cacheDirectory: fixture.cacheDirectory)
    _ = fixture.scanner(capture: FileParseCapture()).scan(provider: .codex, now: fixture.now, historyDays: 30)
    let deletedCacheURL = cache.cacheURL(provider: .codex, sourceURL: fixture.secondUsageURL)
    try FileManager.default.removeItem(at: fixture.secondUsageURL)
    let now = Date().addingTimeInterval(10)
    cache.prune(olderThan: .distantPast, now: now, interval: 0)
    #expect(!FileManager.default.fileExists(atPath: deletedCacheURL.path))

    try Data("{}".utf8).write(to: deletedCacheURL)
    cache.prune(olderThan: .distantPast, now: now.addingTimeInterval(60), interval: 3600)
    #expect(FileManager.default.fileExists(atPath: deletedCacheURL.path))

    cache.prune(olderThan: .distantPast, now: now.addingTimeInterval(3601), interval: 3600)
    #expect(!FileManager.default.fileExists(atPath: deletedCacheURL.path))
  }

  @Test func claudeParseStaysCachedAsTheHistoryWindowSlides() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let log = fixture.root.appendingPathComponent("claude-session.jsonl")
    try Data([
      Self.claudeLine(id: "old", timestamp: "2026-07-01T07:00:00Z", input: 10),
      Self.claudeLine(id: "new", timestamp: "2026-07-28T07:00:00Z", input: 20),
    ].joined(separator: "\n").utf8).write(to: log)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let today = calendar.startOfDay(for: fixture.now)
    let later = try #require(calendar.date(byAdding: .day, value: 3, to: today))
    let window = { (end: Date) throws -> DayRange in
      let start = try #require(calendar.date(byAdding: .day, value: -29, to: end))
      return DayRange(start: start, end: end, calendar: calendar)
    }
    let firstRange = try window(today)
    let slidRange = try window(later)
    let scanner = fixture.scanner(capture: FileParseCapture(), timeZone: calendar.timeZone)
    let first = scanner.scanFile(log, provider: .claude, range: firstRange) {
      scanner.parseClaudeFile(handle: $0, sourcePath: $1, range: firstRange)
    }

    let slid = scanner.scanFile(log, provider: .claude, range: slidRange) { _, _ in
      Issue.record("Expected the cached Claude parse to be reused after the window slid")
      return .failure
    }

    #expect(first.cacheReadTokens == 30)
    #expect(slid.cacheReadTokens == 20)
  }

  private static func claudeLine(id: String, timestamp: String, input: Int) -> String {
    [
      #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req-\#(id)","#,
      #""message":{"id":"msg-\#(id)","model":"claude-sonnet-4-5","#,
      #""usage":{"cache_read_input_tokens":\#(input),"output_tokens":0}}}"#,
    ].joined()
  }
}

private extension LocalUsageFileParseOutcome {
  var cacheReadTokens: Int? {
    guard case let .success(scan) = self else { return nil }
    return scan.records.reduce(0) { $0 + $1.tokens.cacheRead }
  }
}
