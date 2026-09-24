import Foundation

/// Most log lines are prompts, tool output, or transcript text that can never
/// carry usage, and they dominate a log's bytes. A byte search rejects them
/// before `JSONSerialization` builds a full object graph for each one.
enum LocalUsageLineFilter {
  /// Claude usage lives only under `message.usage`.
  static let claudeNeedles = [Data(#""usage""#.utf8)]
  /// Codex usage arrives in `token_count` events, and the model that prices
  /// them can be announced by any line carrying a `model` key.
  static let codexNeedles = [Data(#""token_count""#.utf8), Data(#""model""#.utf8)]

  static func mayContain(_ needles: [Data], in line: Data) -> Bool {
    needles.contains { line.range(of: $0) != nil }
  }

  /// A skipped line is not parsed, but it still has to look like a whole JSON
  /// object: a line cut off by an active writer must keep failing the parse so
  /// a total is never cached before that line completes.
  static func looksLikeCompleteObject(_ line: Data) -> Bool {
    guard let first = line.first(where: { !isWhitespace($0) }),
          let last = line.last(where: { !isWhitespace($0) })
    else { return false }
    return first == UInt8(ascii: "{") && last == UInt8(ascii: "}")
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }
}
