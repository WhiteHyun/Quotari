import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageFileScanMemoTests {
  @Test func warmRescanReusesMemoWithoutParsingOrReadingTheDiskCache() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    _ = fixture.memoScanner(memo: memo, capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let capture = FileParseCapture()
    let diskLoads = FileParseCapture()

    let warm = fixture.memoScanner(memo: memo, capture: capture, diskLoads: diskLoads).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(warm.memoTotalInputTokens == 300)
    #expect(capture.paths.isEmpty)
    #expect(diskLoads.paths.isEmpty)
    #expect(memo.count == 2)
  }

  @Test func appendedFileIsTheOnlyOneReparsedAndTotalsMatchAColdScan() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    _ = fixture.memoScanner(memo: memo, capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    try fixture.appendUsage(to: fixture.firstUsageURL, input: 50)
    let capture = FileParseCapture()

    let warm = fixture.memoScanner(memo: memo, capture: capture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    try FileManager.default.removeItem(at: fixture.cacheDirectory)
    let cold = fixture.scanner(capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(capture.paths == [fixture.firstUsageURL.lastPathComponent])
    #expect(warm.memoTotalInputTokens == 350)
    #expect(warm.memoTotalInputTokens == cold.memoTotalInputTokens)
  }

  @Test func sameSizeRewriteWithRestoredModificationDateMissesTheMemo() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    _ = fixture.memoScanner(memo: memo, capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.firstUsageURL.path)
    let modifiedAt = try #require(attributes[.modificationDate] as? Date)
    Thread.sleep(forTimeInterval: 0.01)
    try fixture.rewriteUsage(to: fixture.firstUsageURL, input: 900)
    try FileManager.default.setAttributes(
      [.modificationDate: modifiedAt],
      ofItemAtPath: fixture.firstUsageURL.path
    )
    let capture = FileParseCapture()

    let rescanned = fixture.memoScanner(memo: memo, capture: capture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(rescanned.memoTotalInputTokens == 1100)
    #expect(capture.paths == [fixture.firstUsageURL.lastPathComponent])
  }

  @Test func replacedFileAtTheSamePathMissesTheMemo() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    _ = fixture.memoScanner(memo: memo, capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let replacement = fixture.root.appendingPathComponent("replacement.jsonl")
    try FileManager.default.copyItem(at: fixture.secondUsageURL, to: replacement)
    try FileManager.default.removeItem(at: fixture.firstUsageURL)
    try FileManager.default.moveItem(at: replacement, to: fixture.firstUsageURL)
    let capture = FileParseCapture()

    let rescanned = fixture.memoScanner(memo: memo, capture: capture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(rescanned.memoTotalInputTokens == 400)
    #expect(capture.paths == [fixture.firstUsageURL.lastPathComponent])
  }

  @Test func linkRetargetedToAnotherNameOfTheSameInodeMissesTheMemo() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    let alias = fixture.root.appendingPathComponent("first-alias.jsonl")
    let link = fixture.root.appendingPathComponent("active.jsonl")
    try FileManager.default.linkItem(at: fixture.firstUsageURL, to: alias)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.firstUsageURL.path)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let start = try #require(calendar.date(byAdding: .day, value: -29, to: fixture.now))
    let range = DayRange(start: start, end: fixture.now, calendar: calendar)
    let scanner = fixture.memoScanner(memo: memo, capture: FileParseCapture(), timeZone: calendar.timeZone)
    _ = scanner.scanFile(link, provider: .codex, range: range) {
      scanner.parseCodexFile(handle: $0, sourcePath: $1, range: range)
    }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: alias.path)

    let rescanned = scanner.scanFile(link, provider: .codex, range: range) {
      scanner.parseCodexFile(handle: $0, sourcePath: $1, range: range)
    }

    #expect(rescanned.sessionIDs == [ProviderCredentialIdentity.fingerprint(of: alias.standardizedFileURL.path)])
  }

  @Test func deletedFileNoLongerContributesToTheScan() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    _ = fixture.memoScanner(memo: memo, capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    try FileManager.default.removeItem(at: fixture.secondUsageURL)

    let rescanned = fixture.memoScanner(memo: memo, capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(rescanned.memoTotalInputTokens == 100)
  }

  @Test func timeZoneChangeMissesTheMemo() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    _ = fixture.memoScanner(memo: memo, capture: FileParseCapture(), timeZone: utc).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let capture = FileParseCapture()

    _ = fixture.memoScanner(memo: memo, capture: capture, timeZone: losAngeles).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(capture.paths.count == 2)
  }

  /// A log event cancels the in-flight scan and starts a replacement; files
  /// the cancelled scan finished must not be parsed again.
  @Test func replacementScanReusesFilesACancelledScanAlreadyParsed() async throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    let cancelledCapture = FileParseCapture()
    let cancellingScanner = LocalUsageCostScanner(
      environment: ["CODEX_HOME": fixture.codexHome.path],
      homeDirectory: fixture.root,
      fileScanCacheDirectory: fixture.cacheDirectory,
      fileScanMemo: memo,
      onFileParsed: { url in
        cancelledCapture.record(url)
        withUnsafeCurrentTask { $0?.cancel() }
      }
    )
    let now = fixture.now

    let cancelled = await Task.detached {
      cancellingScanner.scan(provider: .codex, now: now, historyDays: 30)
    }.value
    let capture = FileParseCapture()
    let replacement = fixture.memoScanner(memo: memo, capture: capture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    guard case .cancelled = cancelled.outcome else {
      Issue.record("Expected the first scan to observe cancellation")
      return
    }
    #expect(cancelledCapture.paths == [fixture.firstUsageURL.lastPathComponent])
    #expect(capture.paths == [fixture.secondUsageURL.lastPathComponent])
    #expect(replacement.memoTotalInputTokens == 300)
  }

  @Test func pruneDropsEntriesOutsideTheWindowForThatProviderOnly() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let memo = LocalUsageFileScanMemo()
    _ = fixture.memoScanner(memo: memo, capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    memo.prune(provider: .claude, olderThan: .distantFuture)
    #expect(memo.count == 2)
    memo.prune(provider: .codex, olderThan: .distantFuture)
    #expect(memo.isEmpty)
  }
}

private extension FileScanFixture {
  func memoScanner(
    memo: LocalUsageFileScanMemo,
    capture: FileParseCapture,
    diskLoads: FileParseCapture? = nil,
    timeZone: TimeZone? = nil
  ) -> LocalUsageCostScanner {
    var calendar = Calendar(identifier: .gregorian)
    if let timeZone {
      calendar.timeZone = timeZone
    }
    let onCacheLoaded: (@Sendable (URL) -> Void)? = if let diskLoads {
      diskLoads.record
    } else {
      nil
    }
    return LocalUsageCostScanner(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: root,
      calendar: calendar,
      fileScanCacheDirectory: cacheDirectory,
      fileScanMemo: memo,
      diskCachePruneInterval: 0,
      onFileParsed: capture.record,
      onCacheLoaded: onCacheLoaded
    )
  }
}

private extension LocalUsageScan {
  var memoTotalInputTokens: Int? {
    guard case let .success(result) = outcome else { return nil }
    return result.records.reduce(0) { $0 + $1.tokens.input }
  }
}
