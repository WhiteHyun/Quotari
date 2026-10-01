import Foundation

/// One Claude usage row, kept with its line order and dedup key so the same
/// parse can be resolved for any history window.
struct ClaudeUsageEvent: Codable, Equatable, Sendable {
  enum Payload: Codable, Equatable, Sendable {
    case record(LocalTokenRecord)
    case unsupported(LocalUnsupportedUsage)
  }

  let lineNumber: Int
  let key: String?
  let payload: Payload

  var day: Date {
    switch payload {
    case let .record(record): record.day
    case let .unsupported(usage): usage.day
    }
  }
}

/// Claude streams the same message several times under one key; only the last
/// row inside the requested window counts, and an out-of-window duplicate must
/// never replace it. Resolving per window keeps a cached parse valid while the
/// window slides, so a new day no longer forces every Claude log to reparse.
///
/// Within one key and day, only the last record and last unsupported row can
/// ever win, because a window contains either all rows of a day or none; the
/// parse keeps just those.
struct ClaudeUsageEvents {
  private struct DayKey: Hashable {
    let key: String
    let day: Date
  }

  var lineNumber = 0
  private var unkeyed: [ClaudeUsageEvent] = []
  private var lastRecords: [DayKey: ClaudeUsageEvent] = [:]
  private var lastUnsupported: [DayKey: ClaudeUsageEvent] = [:]

  var events: [ClaudeUsageEvent] {
    (unkeyed + Array(lastRecords.values) + Array(lastUnsupported.values))
      .sorted { $0.lineNumber < $1.lineNumber }
  }

  mutating func append(record: LocalTokenRecord, key: String?) {
    let event = ClaudeUsageEvent(lineNumber: lineNumber, key: key, payload: .record(record))
    if let key {
      lastRecords[DayKey(key: key, day: record.day)] = event
    } else {
      unkeyed.append(event)
    }
  }

  mutating func appendUnsupportedUsage(
    day: Date,
    model: String,
    sessionID: String,
    key: String?,
    hasPositiveUsage: Bool
  ) {
    guard hasPositiveUsage else { return }
    let usage = LocalUnsupportedUsage(day: day, model: model, sessionID: sessionID)
    let event = ClaudeUsageEvent(lineNumber: lineNumber, key: key, payload: .unsupported(usage))
    if let key {
      lastUnsupported[DayKey(key: key, day: day)] = event
    } else {
      unkeyed.append(event)
    }
  }

  static func resolve(
    _ events: [ClaudeUsageEvent],
    in range: DayRange
  ) -> (records: [LocalTokenRecord], unsupportedUsage: [LocalUnsupportedUsage]) {
    guard !events.isEmpty else { return ([], []) }
    var records: [(lineNumber: Int, record: LocalTokenRecord)] = []
    var keyedRecords: [String: (lineNumber: Int, record: LocalTokenRecord)] = [:]
    var unsupported: [LocalUnsupportedUsage] = []
    var keyedUnsupported: [String: LocalUnsupportedUsage] = [:]
    for event in events where range.day(containing: event.day) != nil {
      switch event.payload {
      case let .record(record):
        if let key = event.key {
          keyedRecords[key] = (event.lineNumber, record)
          keyedUnsupported[key] = nil
        } else {
          records.append((event.lineNumber, record))
        }
      case let .unsupported(usage):
        if let key = event.key {
          keyedUnsupported[key] = usage
        } else {
          unsupported.append(usage)
        }
      }
    }
    return (
      (records + keyedRecords.values).sorted { $0.lineNumber < $1.lineNumber }.map(\.record),
      unsupported + Array(keyedUnsupported.values)
    )
  }
}
