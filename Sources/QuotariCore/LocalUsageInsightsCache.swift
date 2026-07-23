import Foundation

struct LocalUsageInsightsCache {
  static let schemaVersion = 1

  private let cacheDirectory: URL
  private let fileManager: FileManager
  private let maxAge: TimeInterval
  private let calendar = Calendar(identifier: .gregorian)

  init(
    cacheDirectory: URL,
    fileManager: FileManager = .default,
    maxAge: TimeInterval = 7 * 24 * 3600
  ) {
    self.cacheDirectory = cacheDirectory
    self.fileManager = fileManager
    self.maxAge = maxAge
  }

  func load(
    scopeKey: UsageInsightsScopeKey,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary? {
    let url = cacheURL(scopeKey: scopeKey, historyDays: historyDays)
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
      try? fileManager.removeItem(at: url)
      return nil
    }
    guard entry.schemaVersion == Self.schemaVersion,
          entry.historyDays == historyDays,
          entry.scopeKey == scopeKey,
          entry.summary.scopeKey == scopeKey,
          entry.cachedAt <= now.addingTimeInterval(300),
          now.timeIntervalSince(entry.cachedAt) <= maxAge,
          cacheWindowMatches(entry: entry, now: now, historyDays: historyDays)
    else { return nil }
    return entry.summary
  }

  func save(
    _ summary: UsageInsightsSummary,
    now: Date,
    historyDays: Int
  ) {
    let entry = Entry(
      schemaVersion: Self.schemaVersion,
      cachedAt: now,
      historyDays: historyDays,
      scopeKey: summary.scopeKey,
      summary: summary
    )
    guard let data = try? JSONEncoder().encode(entry) else { return }
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? data.write(
      to: cacheURL(scopeKey: summary.scopeKey, historyDays: historyDays),
      options: [.atomic]
    )
  }

  func remove(scopeKey: UsageInsightsScopeKey, historyDays: Int) {
    try? fileManager.removeItem(at: cacheURL(scopeKey: scopeKey, historyDays: historyDays))
  }

  func cacheURL(scopeKey: UsageInsightsScopeKey, historyDays: Int) -> URL {
    let scopeHash = ProviderCredentialIdentity.fingerprint(of: scopeKey.accountScopeID)
    return cacheDirectory.appendingPathComponent(
      "v\(Self.schemaVersion)-\(scopeKey.provider.rawValue)-\(historyDays)-\(scopeHash).json",
      isDirectory: false
    )
  }

  private func cacheWindowMatches(entry: Entry, now: Date, historyDays: Int) -> Bool {
    let today = calendar.startOfDay(for: now)
    guard calendar.startOfDay(for: entry.cachedAt) == today,
          entry.summary.daily.count == historyDays,
          entry.summary.daily.last?.date == today
    else { return false }
    return true
  }

  private struct Entry: Codable {
    var schemaVersion: Int
    var cachedAt: Date
    var historyDays: Int
    var scopeKey: UsageInsightsScopeKey
    var summary: UsageInsightsSummary
  }
}
