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
}
