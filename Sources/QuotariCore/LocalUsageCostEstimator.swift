import Foundation

public protocol UsageCostEstimating: Sendable {
  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary?
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary?
  func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int)
  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> CostSummary?
  func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> CostSummary?
  func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  )
}

public extension UsageCostEstimating {
  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary? {
    nil
  }

  func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int) {}

  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> CostSummary? {
    cachedCostSummary(provider: provider, now: now, historyDays: historyDays)
  }

  func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> CostSummary? {
    await costSummary(provider: provider, now: now, historyDays: historyDays)
  }

  func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  ) {
    invalidateCachedCostSummary(provider: provider, historyDays: historyDays)
  }
}

public struct LocalUsageCostEstimator: UsageCostEstimating {
  private let environment: [String: String]
  private let homeDirectory: URL
  private let cacheDirectory: URL

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    cacheDirectory: URL? = nil
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.cacheDirectory = cacheDirectory ?? homeDirectory
      .appendingPathComponent("Library/Caches/Quotari/LocalUsageCost", isDirectory: true)
  }

  public func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int = 30) -> CostSummary? {
    cachedCostSummary(provider: provider, account: nil, now: now, historyDays: historyDays)
  }

  public func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) -> CostSummary? {
    LocalUsageCostCache(cacheDirectory: cacheDirectory)
      .load(provider: provider, scopeID: account?.id, now: now, historyDays: historyDays)
  }

  public func costSummary(provider: UsageProvider, now: Date, historyDays: Int = 30) async -> CostSummary? {
    await costSummary(provider: provider, account: nil, now: now, historyDays: historyDays)
  }

  public func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) async -> CostSummary? {
    let environment = environment
    let homeDirectory = homeDirectory
    let cacheDirectory = cacheDirectory
    return await Task.detached(priority: .utility) {
      let summary = LocalUsageCostScanner(
        environment: environment,
        homeDirectory: homeDirectory
      ).costSummary(provider: provider, account: account, now: now, historyDays: historyDays)
      if let summary {
        LocalUsageCostCache(cacheDirectory: cacheDirectory)
          .save(
            summary,
            provider: provider,
            scopeID: account?.id,
            now: now,
            historyDays: historyDays
          )
      }
      return summary
    }.value
  }

  public func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int = 30) {
    invalidateCachedCostSummary(provider: provider, account: nil, historyDays: historyDays)
  }

  public func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int = 30
  ) {
    LocalUsageCostCache(cacheDirectory: cacheDirectory)
      .remove(provider: provider, scopeID: account?.id, historyDays: historyDays)
  }
}

struct LocalUsageCostScanner {
  private let environment: [String: String]
  private let homeDirectory: URL
  private let fileManager: FileManager
  private let calendar = Calendar(identifier: .gregorian)

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
  }

  func costSummary(
    provider: UsageProvider,
    account: ProviderAccount? = nil,
    now: Date,
    historyDays: Int = 30
  ) -> CostSummary? {
    let historyDays = max(1, min(365, historyDays))
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -(historyDays - 1), to: today) ?? today
    let range = DayRange(start: start, end: today, calendar: calendar)
    let records: [LocalTokenRecord] = switch provider {
    case .codex:
      scanCodex(range: range, account: account)
    case .claude:
      scanClaude(range: range, account: account)
    case .glm:
      []
    }
    return LocalCostSummaryBuilder.summary(
      provider: provider,
      records: records,
      range: range,
      pricing: LocalModelPricing(),
      sourceDescription: sourceDescription(account: account)
    )
  }

  private func scanCodex(range: DayRange, account: ProviderAccount?) -> [LocalTokenRecord] {
    codexRoots(account: account).flatMap { root in
      jsonlFiles(in: root, modifiedSince: range.start).flatMap { parseCodexFile($0, range: range) }
    }
  }

  private func scanClaude(range: DayRange, account: ProviderAccount?) -> [LocalTokenRecord] {
    claudeProjectRoots(account: account).flatMap { root in
      jsonlFiles(in: root, modifiedSince: range.start).flatMap { parseClaudeFile($0, range: range) }
    }
  }

  private func codexRoots(account: ProviderAccount?) -> [URL] {
    if let account,
       case let .codexAuthFile(path) = account.credentialSource {
      return codexRoots(home: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    let home: URL = {
      if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
         !raw.isEmpty {
        return URL(fileURLWithPath: raw, isDirectory: true)
      }
      return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }()

    return codexRoots(home: home)
  }

  private func codexRoots(home: URL) -> [URL] {
    let roots = [
      home.appendingPathComponent("sessions", isDirectory: true),
      home.appendingPathComponent("archived_sessions", isDirectory: true),
    ]
    return roots.filter { fileManager.fileExists(atPath: $0.path) }
  }

  private func claudeProjectRoots(account: ProviderAccount?) -> [URL] {
    if let account,
       case let .claudeCredentialsFile(path) = account.credentialSource {
      let config = URL(fileURLWithPath: path).deletingLastPathComponent()
      let projects = config.appendingPathComponent("projects", isDirectory: true)
      return fileManager.fileExists(atPath: projects.path) ? [projects] : []
    }

    let roots: [URL] = if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty {
      raw.split(separator: ",").map { part in
        let url = URL(fileURLWithPath: String(part).trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        return url.lastPathComponent == "projects" ? url : url.appendingPathComponent("projects", isDirectory: true)
      }
    } else {
      [
        homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true),
        homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
      ] + ClaudeDesktopProjectRoots.locate(homeDirectory: homeDirectory, fileManager: fileManager)
    }
    return deduplicated(roots).filter { fileManager.fileExists(atPath: $0.path) }
  }

  private func sourceDescription(account: ProviderAccount?) -> String? {
    guard let account else { return nil }
    return switch account.credentialSource {
    case .codexAuthFile:
      "Estimated from selected account's local Codex logs"
    case .claudeCredentialsFile:
      "Estimated from selected account's local Claude cache logs"
    case .claudeEnvironment, .claudeKeychain:
      "Estimated from local Claude cache logs (not account-specific)"
    }
  }

  private func jsonlFiles(in root: URL, modifiedSince: Date) -> [URL] {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsPackageDescendants]
    ) else { return [] }

    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      if let modified = values?.contentModificationDate, modified < modifiedSince {
        continue
      }
      urls.append(url)
    }
    return urls.sorted { $0.path < $1.path }
  }

  private func parseCodexFile(_ url: URL, range: DayRange) -> [LocalTokenRecord] {
    guard let lines = lines(in: url) else { return [] }
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
      records.append(LocalTokenRecord(day: day, model: model, tokens: tokens))
    }
    return records
  }

  private func codexModel(from object: [String: Any]) -> String? {
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

  private func parseClaudeFile(_ url: URL, range: DayRange) -> [LocalTokenRecord] {
    guard let lines = lines(in: url) else { return [] }
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
        record: LocalTokenRecord(day: day, model: model, tokens: tokens)
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

  private func lines(in url: URL) -> [Substring]? {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text.split(whereSeparator: \.isNewline)
  }

  private func jsonObject(from line: Substring) -> [String: Any]? {
    guard let data = String(line).data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func timestamp(from object: [String: Any]) -> Date? {
    LenientDateParser.parse(object["timestamp"] ?? object["created_at"] ?? object["createdAt"])
  }

  private func tokenTotals(from value: Any?) -> TokenTotals? {
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

  private func claudeTokenTotals(from usage: [String: Any]) -> TokenTotals? {
    // Claude assistant JSONL rows currently expose placeholder input/output counts.
    let totals = TokenTotals(
      input: 0,
      cacheRead: int(usage["cache_read_input_tokens"]),
      cacheWrite: int(usage["cache_creation_input_tokens"]),
      output: 0
    )
    return totals.total > 0 ? totals : nil
  }

  private func claudeUsageKey(from object: [String: Any], message: [String: Any]) -> String? {
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

  private func int(_ value: Any?) -> Int {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) ?? 0 }
    return 0
  }

  private func string(_ value: Any?) -> String? {
    (value as? String).flatMap {
      let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  private func deduplicated(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for url in urls {
      let canonical = url.resolvingSymlinksInPath().standardizedFileURL
      guard seen.insert(canonical.path).inserted else { continue }
      result.append(canonical)
    }
    return result
  }
}

private struct PendingClaudeTokenRecord {
  let lineNumber: Int
  let record: LocalTokenRecord
}
