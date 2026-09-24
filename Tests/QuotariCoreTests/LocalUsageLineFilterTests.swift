import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageLineFilterTests {
  @Test func linesWithoutAnyNeedleAreSkipped() {
    let line = Data(#"{"type":"user","message":{"content":"hello"}}"#.utf8)

    #expect(!LocalUsageLineFilter.mayContain(LocalUsageLineFilter.claudeNeedles, in: line))
    #expect(!LocalUsageLineFilter.mayContain(LocalUsageLineFilter.codexNeedles, in: line))
  }

  @Test func usageAndModelLinesAreParsed() {
    let claude = Data(#"{"type":"assistant","message":{"usage":{"output_tokens":1}}}"#.utf8)
    let codexModel = Data(#"{"type":"turn_context","payload":{"model":"gpt-5"}}"#.utf8)
    let codexUsage = Data(#"{"type":"event_msg","payload":{"type":"token_count"}}"#.utf8)

    #expect(LocalUsageLineFilter.mayContain(LocalUsageLineFilter.claudeNeedles, in: claude))
    #expect(LocalUsageLineFilter.mayContain(LocalUsageLineFilter.codexNeedles, in: codexModel))
    #expect(LocalUsageLineFilter.mayContain(LocalUsageLineFilter.codexNeedles, in: codexUsage))
  }

  @Test(arguments: [
    (#"{"type":"user"}"#, true),
    ("  {\"a\":1}\t", true),
    (#"{"type":"user","message":{"content":"cut off"#, false),
    ("not-json", false),
    ("", false),
  ])
  func completeObjectShapeIsRequiredForSkippedLines(line: String, expected: Bool) {
    #expect(LocalUsageLineFilter.looksLikeCompleteObject(Data(line.utf8)) == expected)
  }

  @Test func truncatedTrailingLineStillFailsTheParse() throws {
    let fixture = try FileScanFixture()
    defer { fixture.cleanup() }
    var content = try Data(contentsOf: fixture.firstUsageURL)
    content.append(Data("\n{\"type\":\"response_item\",\"payload\":{\"content\":\"partial".utf8))
    try content.write(to: fixture.firstUsageURL)

    let scan = fixture.scanner(capture: FileParseCapture()).scan(
      provider: .codex,
      now: fixture.now,
      historyDays: 30
    )

    guard case .failure = scan.outcome else {
      Issue.record("Expected a truncated trailing line to fail the parse")
      return
    }
  }
}
