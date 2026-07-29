import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageFileScanCacheTests {
  @Test func unchangedFilesReuseCachedParseResultsAndChangedFilesReparse() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let firstCapture = FileParseCapture()
    let firstScanner = fixture.scanner(capture: firstCapture)

    let first = firstScanner.scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(first.recordCount == 2)
    #expect(firstCapture.paths.count == 2)

    let warmCapture = FileParseCapture()
    let warm = fixture.scanner(capture: warmCapture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(warm.recordCount == 2)
    #expect(warmCapture.paths.isEmpty)

    try fixture.appendUsage(to: fixture.firstUsageURL, input: 50)
    let changedCapture = FileParseCapture()
    let changed = fixture.scanner(capture: changedCapture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(changed.recordCount == 3)
    #expect(changedCapture.paths == [fixture.firstUsageURL.lastPathComponent])
  }

  @Test func lineStreamingStopsCooperativelyWhenItsTaskIsCancelled() async throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    try fixture.appendUsage(to: fixture.firstUsageURL, input: 50)
    let scanner = fixture.scanner(capture: FileParseCapture())

    let outcome = await Task.detached {
      scanner.forEachLine(in: fixture.firstUsageURL) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return true
      }
    }.value

    guard case .cancelled = outcome else {
      Issue.record("Expected streaming parser to observe task cancellation")
      return
    }
  }

  @Test func unterminatedMultiChunkLineResumesSearchingAtTheAppendBoundary() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let scanner = fixture.scanner(capture: FileParseCapture())
    var pending = Data(repeating: 0x61, count: 512 * 1024)
    var searchOffset = 0

    let initial = scanner.consumeCompleteLines(
      from: &pending,
      newlineSearchOffset: &searchOffset,
      body: { _ in true }
    )

    #expect(initial == nil)
    #expect(searchOffset == pending.count)
    pending.append(contentsOf: [0x62, 0x0A])
    var consumedLine: Data?

    let completed = scanner.consumeCompleteLines(
      from: &pending,
      newlineSearchOffset: &searchOffset,
      body: {
        consumedLine = $0
        return true
      }
    )

    #expect(completed == nil)
    #expect(consumedLine?.count == (512 * 1024) + 1)
    #expect(pending.isEmpty)
    #expect(searchOffset == 0)
  }

  @Test func corruptCacheEntryIsDiscardedAndRebuilt() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let firstCapture = FileParseCapture()
    _ = fixture.scanner(capture: firstCapture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let cache = LocalUsageFileScanCache(cacheDirectory: fixture.cacheDirectory)
    let cacheURL = cache.cacheURL(provider: .codex, sourceURL: fixture.firstUsageURL)
    try Data("corrupt".utf8).write(to: cacheURL)
    let rebuildCapture = FileParseCapture()

    let rebuilt = fixture.scanner(capture: rebuildCapture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(rebuilt.recordCount == 2)
    #expect(rebuildCapture.paths == [fixture.firstUsageURL.lastPathComponent])
  }

  @Test func cacheEntryIsPrunedWhenItsSourceFileIsDeleted() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    _ = fixture.scanner(capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let cache = LocalUsageFileScanCache(cacheDirectory: fixture.cacheDirectory)
    let deletedCacheURL = cache.cacheURL(
      provider: .codex,
      sourceURL: fixture.secondUsageURL
    )
    #expect(FileManager.default.fileExists(atPath: deletedCacheURL.path))
    try FileManager.default.removeItem(at: fixture.secondUsageURL)

    let rescanned = fixture.scanner(capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(rescanned.recordCount == 1)
    #expect(!FileManager.default.fileExists(atPath: deletedCacheURL.path))
  }

  @Test func sameSizeRewriteWithRestoredModificationDateInvalidatesCache() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    _ = fixture.scanner(capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.firstUsageURL.path
    )
    let modifiedAt = try #require(attributes[.modificationDate] as? Date)
    Thread.sleep(forTimeInterval: 0.01)
    try fixture.rewriteUsage(to: fixture.firstUsageURL, input: 900)
    try FileManager.default.setAttributes(
      [.modificationDate: modifiedAt],
      ofItemAtPath: fixture.firstUsageURL.path
    )
    let capture = FileParseCapture()

    let rescanned = fixture.scanner(capture: capture).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(rescanned.totalInputTokens == 1100)
    #expect(capture.paths == [fixture.firstUsageURL.lastPathComponent])
  }

  @Test func timeZoneChangeInvalidatesCalendarNormalizedCache() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    _ = fixture.scanner(capture: FileParseCapture(), timeZone: utc).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let capture = FileParseCapture()

    let rescanned = fixture.scanner(capture: capture, timeZone: losAngeles).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = losAngeles
    let timestamp = try #require(LenientDateParser.parse("2026-07-28T07:00:00Z"))

    #expect(rescanned.firstRecordDay == calendar.startOfDay(for: timestamp))
    #expect(capture.paths == [
      fixture.firstUsageURL.lastPathComponent,
      fixture.secondUsageURL.lastPathComponent,
    ])
  }

  @Test func cacheHitIsRevalidatedBeforeReturningCachedRecords() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    _ = fixture.scanner(capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )
    let capture = FileParseCapture()
    let scanner = fixture.scanner(
      capture: capture,
      onCacheLoaded: { url in
        guard url.lastPathComponent == fixture.firstUsageURL.lastPathComponent else {
          return
        }
        try? fixture.rewriteUsage(to: url, input: 900)
      }
    )

    let rescanned = scanner.scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    #expect(rescanned.totalInputTokens == 1100)
    #expect(capture.paths == [fixture.firstUsageURL.lastPathComponent])
  }

  @Test func fingerprintAndParserStayBoundToTheSameOpenFile() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    let link = fixture.root.appendingPathComponent("active.jsonl")
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
    let scanner = fixture.scanner(capture: FileParseCapture(), timeZone: calendar.timeZone)

    let first = scanner.scanFile(link, provider: .codex, range: range) { handle, sourcePath in
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: fixture.secondUsageURL.path
      )
      return scanner.parseCodexFile(
        handle: handle,
        sourcePath: sourcePath,
        range: range
      )
    }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: fixture.firstUsageURL.path
    )
    let warm = scanner.scanFile(link, provider: .codex, range: range) { _, _ in
      Issue.record("Expected the descriptor-bound parse to be reused")
      return .failure
    }
    let expectedSessionID = ProviderCredentialIdentity.fingerprint(
      of: fixture.firstUsageURL.standardizedFileURL.path
    )

    #expect(first.totalInputTokens == 100)
    #expect(first.sessionIDs == [expectedSessionID])
    #expect(warm.totalInputTokens == 100)
  }
}

final class FileParseCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var paths: [String] {
    lock.withLock { storage }
  }

  func record(_ url: URL) {
    lock.withLock { storage.append(url.lastPathComponent) }
  }
}

struct FileScanFixture {
  let root: URL
  let codexHome: URL
  let sessions: URL
  let cacheDirectory: URL
  let firstUsageURL: URL
  let secondUsageURL: URL
  let now: Date

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-file-scan-cache-\(UUID().uuidString)", isDirectory: true)
    codexHome = root.appendingPathComponent("codex", isDirectory: true)
    sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    cacheDirectory = root.appendingPathComponent("file-scans", isDirectory: true)
    firstUsageURL = sessions.appendingPathComponent("first.jsonl")
    secondUsageURL = sessions.appendingPathComponent("second.jsonl")
    now = try #require(LenientDateParser.parse("2026-07-28T08:00:00Z"))
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try writeUsage(to: firstUsageURL, input: 100)
    try writeUsage(to: secondUsageURL, input: 200)
  }

  func scanner(
    capture: FileParseCapture,
    timeZone: TimeZone? = nil,
    onCacheLoaded: (@Sendable (URL) -> Void)? = nil
  ) -> LocalUsageCostScanner {
    var calendar = Calendar(identifier: .gregorian)
    if let timeZone {
      calendar.timeZone = timeZone
    }
    return LocalUsageCostScanner(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: root,
      calendar: calendar,
      fileScanCacheDirectory: cacheDirectory,
      onFileParsed: capture.record,
      onCacheLoaded: onCacheLoaded
    )
  }

  func appendUsage(to url: URL, input: Int) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n\(usageLine(input: input))".utf8))
  }

  func rewriteUsage(to url: URL, input: Int) throws {
    try Data(usageLine(input: input).utf8).write(to: url)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  private func writeUsage(to url: URL, input: Int) throws {
    try Data(usageLine(input: input).utf8).write(to: url)
  }

  private func usageLine(input: Int) -> String {
    [
      #"{"type":"event_msg","timestamp":"2026-07-28T07:00:00Z","payload":{"type":"token_count","info":{"model":"gpt-5","#,
      #""last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0}}}}"#,
    ].joined()
  }
}

private extension LocalUsageScan {
  var recordCount: Int? {
    guard case let .success(result) = outcome else { return nil }
    return result.records.count
  }

  var totalInputTokens: Int? {
    guard case let .success(result) = outcome else { return nil }
    return result.records.reduce(0) { $0 + $1.tokens.input }
  }

  var firstRecordDay: Date? {
    guard case let .success(result) = outcome else { return nil }
    return result.records.first?.day
  }
}

extension LocalUsageFileParseOutcome {
  var totalInputTokens: Int? {
    guard case let .success(scan) = self else { return nil }
    return scan.records.reduce(0) { $0 + $1.tokens.input }
  }

  var sessionIDs: Set<String>? {
    guard case let .success(scan) = self else { return nil }
    return Set(scan.records.compactMap(\.sessionID))
  }
}
