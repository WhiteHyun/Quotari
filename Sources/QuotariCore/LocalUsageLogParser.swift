import Foundation

extension LocalUsageCostScanner {
  func parseCodexFile(
    _ url: URL,
    handle: FileHandle,
    range: DayRange
  ) -> LocalUsageFileParseOutcome {
    let sessionID = localSessionID(for: url)
    var previousTotals: TokenTotals?
    var currentModel: String?
    var records: [LocalTokenRecord] = []
    var unsupportedUsage: [LocalUnsupportedUsage] = []

    let readOutcome = forEachLine(handle: handle) { line in
      // A trailing partial line is expected while a writer is active, but
      // caching a total before that line completes would undercount. Preserve
      // the previous summary until every observed line is valid JSON.
      guard let object = jsonObject(from: line) else { return false }
      if let model = codexModel(from: object) {
        currentModel = model
      }

      guard object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let timestamp = timestamp(from: object)
      else { return true }

      let model = string(info["model"]) ?? currentModel
      let tokens = codexTokens(from: info, previousTotals: &previousTotals)
      let day = range.calendar.startOfDay(for: timestamp)
      guard let tokens else {
        if hasPositiveCodexUsage(in: info) {
          unsupportedUsage.append(
            LocalUnsupportedUsage(day: day, model: model, sessionID: sessionID)
          )
        }
        return true
      }
      guard tokens.total > 0 else { return true }
      records.append(LocalTokenRecord(
        day: day,
        model: model,
        tokens: tokens,
        contextInputTokens: codexContextInputTokens(from: info["last_token_usage"])
          ?? (tokens.input + tokens.cacheRead + tokens.cacheWrite),
        sessionID: sessionID
      ))
      return true
    }
    return switch readOutcome {
    case .completed:
      .success(LocalUsageFileScan(records: records, unsupportedUsage: unsupportedUsage))
    case .cancelled:
      .cancelled
    case .failure:
      .failure
    }
  }

  func parseClaudeFile(
    _ url: URL,
    handle: FileHandle,
    range: DayRange
  ) -> LocalUsageFileParseOutcome {
    let sessionID = localSessionID(for: url)
    var state = ClaudeFileParseState()

    let readOutcome = forEachLine(handle: handle) { line in
      consumeClaudeLine(line, sessionID: sessionID, range: range, state: &state)
    }
    return switch readOutcome {
    case .completed:
      .success(state.scan)
    case .cancelled:
      .cancelled
    case .failure:
      .failure
    }
  }

  private func consumeClaudeLine(
    _ line: Data,
    sessionID: String,
    range: DayRange,
    state: inout ClaudeFileParseState
  ) -> Bool {
    defer { state.lineNumber += 1 }
    guard let object = jsonObject(from: line) else { return false }
    guard
      object["type"] as? String == "assistant",
      let timestamp = timestamp(from: object),
      let message = object["message"] as? [String: Any],
      let model = string(message["model"]),
      let usage = message["usage"] as? [String: Any]
    else { return true }
    let day = range.calendar.startOfDay(for: timestamp)

    guard let tokens = claudeTokenTotals(from: usage) else {
      state.appendUnsupportedUsage(
        day: day,
        model: model,
        sessionID: sessionID,
        key: claudeUsageKey(from: object, message: message),
        hasPositiveUsage: hasPositiveUsage(in: usage)
      )
      return true
    }
    state.append(
      record: LocalTokenRecord(
        day: day,
        model: model,
        tokens: tokens,
        contextInputTokens: claudeContextInputTokens(from: usage),
        sessionID: sessionID
      ),
      key: claudeUsageKey(from: object, message: message)
    )
    return true
  }
}

extension LocalUsageCostScanner {
  func codexModel(from object: [String: Any]) -> String? {
    if let model = string(object["model"]) {
      return model
    }
    guard let payload = object["payload"] as? [String: Any] else { return nil }
    if let model = string(payload["model"]) {
      return model
    }
    if let info = payload["info"] as? [String: Any],
       let model = string(info["model"]) {
      return model
    }
    for key in ["item", "message", "response"] {
      if let nested = payload[key] as? [String: Any],
         let model = string(nested["model"]) {
        return model
      }
    }
    return nil
  }

  func localSessionID(for url: URL) -> String {
    let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
    return ProviderCredentialIdentity.fingerprint(of: canonicalPath)
  }

  func forEachLine(
    in url: URL,
    body: (Data) -> Bool
  ) -> LocalUsageLineReadOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure }
    defer { try? handle.close() }
    return forEachLine(handle: handle, body: body)
  }

  private func forEachLine(
    handle: FileHandle,
    body: (Data) -> Bool
  ) -> LocalUsageLineReadOutcome {
    var pending = Data()
    do {
      while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
        guard !Task.isCancelled else { return .cancelled }
        pending.append(chunk)
        if let outcome = consumeCompleteLines(from: &pending, body: body) {
          return outcome
        }
      }
    } catch {
      return .failure
    }
    guard !Task.isCancelled else { return .cancelled }
    let finalLine = normalizedLine(pending)
    guard finalLine.isEmpty || autoreleasepool(invoking: { body(finalLine) }) else {
      return .failure
    }
    return .completed
  }

  private func consumeCompleteLines(
    from pending: inout Data,
    body: (Data) -> Bool
  ) -> LocalUsageLineReadOutcome? {
    var lineStart = pending.startIndex
    while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
      guard !Task.isCancelled else { return .cancelled }
      let line = normalizedLine(pending.subdata(in: lineStart ..< newline))
      guard line.isEmpty || autoreleasepool(invoking: { body(line) }) else {
        return .failure
      }
      lineStart = pending.index(after: newline)
    }
    if lineStart > pending.startIndex {
      pending.removeSubrange(pending.startIndex ..< lineStart)
    }
    return nil
  }

  func normalizedLine(_ data: Data) -> Data {
    guard data.last == 0x0D else { return data }
    return data.dropLast()
  }

  func jsonObject(from line: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
  }

  func timestamp(from object: [String: Any]) -> Date? {
    LenientDateParser.parse(object["timestamp"] ?? object["created_at"] ?? object["createdAt"])
  }

  func tokenTotals(from value: Any?) -> TokenTotals? {
    guard let fields = value as? [String: Any] else { return nil }
    let cacheRead = int(fields["cached_input_tokens"] ?? fields["cache_read_input_tokens"])
    let totals = TokenTotals(
      input: max(0, int(fields["input_tokens"]) - cacheRead),
      cacheRead: cacheRead,
      cacheWrite: int(fields["cache_creation_input_tokens"]),
      output: int(fields["output_tokens"])
    )
    return totals.total > 0 ? totals : nil
  }

  func codexTokens(
    from info: [String: Any],
    previousTotals: inout TokenTotals?
  ) -> TokenTotals? {
    let total = tokenTotals(from: info["total_token_usage"])
    let tokens = total?.delta(from: previousTotals)
      ?? tokenTotals(from: info["last_token_usage"])
    if let total {
      previousTotals = total
    }
    return tokens
  }

  func claudeTokenTotals(from usage: [String: Any]) -> TokenTotals? {
    // Claude assistant JSONL rows currently expose placeholder input/output counts.
    let totals = TokenTotals(
      input: 0,
      cacheRead: int(usage["cache_read_input_tokens"]),
      cacheWrite: int(usage["cache_creation_input_tokens"]),
      output: 0
    )
    return totals.total > 0 ? totals : nil
  }

  func hasPositiveUsage(in usage: [String: Any]) -> Bool {
    [
      "input_tokens",
      "output_tokens",
      "cache_read_input_tokens",
      "cache_creation_input_tokens",
    ].contains { int(usage[$0]) > 0 }
  }

  func hasPositiveCodexUsage(in info: [String: Any]) -> Bool {
    for key in ["total_token_usage", "last_token_usage"] {
      guard let usage = info[key] as? [String: Any] else { continue }
      if hasPositiveUsage(in: usage) {
        return true
      }
    }
    return false
  }

  func codexContextInputTokens(from value: Any?) -> Int? {
    guard let fields = value as? [String: Any] else { return nil }
    let input = int(fields["input_tokens"])
    let cacheWrite = int(fields["cache_creation_input_tokens"])
    let total = max(0, input) + max(0, cacheWrite)
    return total > 0 ? total : nil
  }

  func claudeContextInputTokens(from usage: [String: Any]) -> Int? {
    let total = max(0, int(usage["input_tokens"]))
      + max(0, int(usage["cache_read_input_tokens"]))
      + max(0, int(usage["cache_creation_input_tokens"]))
    return total > 0 ? total : nil
  }

  func claudeUsageKey(from object: [String: Any], message: [String: Any]) -> String? {
    for value in [
      object["requestId"],
      object["request_id"],
      message["id"],
      object["messageId"],
      object["message_id"],
    ] {
      if let key = string(value) {
        return key
      }
    }
    return nil
  }

  func int(_ value: Any?) -> Int {
    if let int = value as? Int {
      return int
    }
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = value as? String {
      return Int(string) ?? 0
    }
    return 0
  }

  func string(_ value: Any?) -> String? {
    (value as? String).flatMap {
      let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }
}

private struct PendingClaudeTokenRecord {
  let lineNumber: Int
  let record: LocalTokenRecord
}

private struct ClaudeFileParseState {
  var records: [PendingClaudeTokenRecord] = []
  var keyedRecords: [String: PendingClaudeTokenRecord] = [:]
  var unsupportedUsage: [LocalUnsupportedUsage] = []
  var keyedUnsupportedUsage: [String: LocalUnsupportedUsage] = [:]
  var lineNumber = 0

  var scan: LocalUsageFileScan {
    LocalUsageFileScan(
      records: (records + keyedRecords.values)
        .sorted { $0.lineNumber < $1.lineNumber }
        .map(\.record),
      unsupportedUsage: unsupportedUsage + Array(keyedUnsupportedUsage.values)
    )
  }

  mutating func append(record: LocalTokenRecord, key: String?) {
    let pending = PendingClaudeTokenRecord(lineNumber: lineNumber, record: record)
    if let key {
      keyedRecords[key] = pending
      keyedUnsupportedUsage[key] = nil
    } else {
      records.append(pending)
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
    let unsupported = LocalUnsupportedUsage(day: day, model: model, sessionID: sessionID)
    if let key {
      keyedUnsupportedUsage[key] = unsupported
    } else {
      unsupportedUsage.append(unsupported)
    }
  }
}

enum LocalUsageFileParseOutcome: Sendable {
  case success(LocalUsageFileScan)
  case cancelled
  case failure
}

enum LocalUsageLineReadOutcome: Sendable {
  case completed
  case cancelled
  case failure
}

struct LocalUsageFileScan: Codable, Equatable, Sendable {
  let records: [LocalTokenRecord]
  let unsupportedUsage: [LocalUnsupportedUsage]

  func filtered(to range: DayRange) -> LocalUsageFileScan {
    LocalUsageFileScan(
      records: records.filter { range.day(containing: $0.day) != nil },
      unsupportedUsage: unsupportedUsage.filter { range.day(containing: $0.day) != nil }
    )
  }
}
