import Foundation

extension LocalUsageCostScanner {
  func parseCodexFile(_ url: URL, range: DayRange) -> [LocalTokenRecord] {
    guard let lines = lines(in: url) else { return [] }
    let sessionID = localSessionID(for: url)
    var previousTotals: TokenTotals?
    var currentModel: String?
    var records: [LocalTokenRecord] = []

    for line in lines {
      guard let object = jsonObject(from: line) else { continue }
      if let model = codexModel(from: object) {
        currentModel = model
      }

      guard object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let timestamp = timestamp(from: object)
      else { continue }

      let model = string(info["model"]) ?? currentModel
      let total = tokenTotals(from: info["total_token_usage"])
      let last = tokenTotals(from: info["last_token_usage"])
      let tokens: TokenTotals? = if let total {
        total.delta(from: previousTotals)
      } else if let last {
        last
      } else {
        nil
      }
      if let total {
        previousTotals = total
      }
      guard let day = range.day(containing: timestamp) else { continue }
      guard let tokens, tokens.total > 0 else { continue }
      records.append(LocalTokenRecord(
        day: day,
        model: model,
        tokens: tokens,
        contextInputTokens: codexContextInputTokens(from: info["last_token_usage"])
          ?? (tokens.input + tokens.cacheRead + tokens.cacheWrite),
        sessionID: sessionID
      ))
    }
    return records
  }

  func parseClaudeFile(_ url: URL, range: DayRange) -> [LocalTokenRecord] {
    guard let lines = lines(in: url) else { return [] }
    let sessionID = localSessionID(for: url)
    var records: [PendingClaudeTokenRecord] = []
    var keyedRecords: [String: PendingClaudeTokenRecord] = [:]

    for (lineNumber, line) in lines.enumerated() {
      guard let object = jsonObject(from: line),
            object["type"] as? String == "assistant",
            let timestamp = timestamp(from: object),
            let day = range.day(containing: timestamp),
            let message = object["message"] as? [String: Any],
            let model = string(message["model"]),
            let usage = message["usage"] as? [String: Any]
      else { continue }

      guard let tokens = claudeTokenTotals(from: usage) else { continue }
      let record = PendingClaudeTokenRecord(
        lineNumber: lineNumber,
        record: LocalTokenRecord(
          day: day,
          model: model,
          tokens: tokens,
          contextInputTokens: claudeContextInputTokens(from: usage),
          sessionID: sessionID
        )
      )
      if let key = claudeUsageKey(from: object, message: message) {
        keyedRecords[key] = record
      } else {
        records.append(record)
      }
    }
    return (records + keyedRecords.values)
      .sorted { $0.lineNumber < $1.lineNumber }
      .map(\.record)
  }
}

private extension LocalUsageCostScanner {
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

  func lines(in url: URL) -> [Substring]? {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text.split(whereSeparator: \.isNewline)
  }

  func jsonObject(from line: Substring) -> [String: Any]? {
    guard let data = String(line).data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
