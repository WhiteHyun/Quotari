import Foundation

struct LocalUsageCostCache {
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

  func load(provider: UsageProvider, scopeID: String? = nil, now: Date, historyDays: Int) -> CostSummary? {
    guard let data = try? Data(contentsOf: cacheURL(provider: provider, scopeID: scopeID, historyDays: historyDays)),
          let entry = try? JSONDecoder().decode(Entry.self, from: data),
          entry.historyDays == historyDays,
          entry.scopeID == scopeID,
          entry.cachedAt <= now.addingTimeInterval(300),
          now.timeIntervalSince(entry.cachedAt) <= maxAge,
          cacheWindowMatches(entry: entry, now: now, historyDays: historyDays)
    else { return nil }
    return entry.summary
  }

  func save(
    _ summary: CostSummary,
    provider: UsageProvider,
    scopeID: String? = nil,
    now: Date,
    historyDays: Int
  ) {
    let entry = Entry(cachedAt: now, historyDays: historyDays, scopeID: scopeID, summary: summary)
    guard let data = try? JSONEncoder().encode(entry) else { return }
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? data.write(
      to: cacheURL(provider: provider, scopeID: scopeID, historyDays: historyDays),
      options: [.atomic]
    )
  }

  func remove(provider: UsageProvider, scopeID: String? = nil, historyDays: Int) {
    try? fileManager.removeItem(at: cacheURL(provider: provider, scopeID: scopeID, historyDays: historyDays))
  }

  private func cacheURL(provider: UsageProvider, scopeID: String?, historyDays: Int) -> URL {
    let scopeSuffix = scopeID.map { "-\(stableHash($0))" } ?? ""
    return cacheDirectory.appendingPathComponent(
      "\(provider.rawValue)-\(historyDays)\(scopeSuffix).json",
      isDirectory: false
    )
  }

  private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
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
    var cachedAt: Date
    var historyDays: Int
    var scopeID: String?
    var summary: CostSummary
  }
}
