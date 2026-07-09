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

  func load(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary? {
    guard let data = try? Data(contentsOf: cacheURL(provider: provider, historyDays: historyDays)),
          let entry = try? JSONDecoder().decode(Entry.self, from: data),
          entry.historyDays == historyDays,
          entry.cachedAt <= now.addingTimeInterval(300),
          now.timeIntervalSince(entry.cachedAt) <= maxAge,
          cacheWindowMatches(entry: entry, now: now, historyDays: historyDays)
    else { return nil }
    return entry.summary
  }

  func save(_ summary: CostSummary, provider: UsageProvider, now: Date, historyDays: Int) {
    let entry = Entry(cachedAt: now, historyDays: historyDays, summary: summary)
    guard let data = try? JSONEncoder().encode(entry) else { return }
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? data.write(to: cacheURL(provider: provider, historyDays: historyDays), options: [.atomic])
  }

  private func cacheURL(provider: UsageProvider, historyDays: Int) -> URL {
    cacheDirectory.appendingPathComponent("\(provider.rawValue)-\(historyDays).json", isDirectory: false)
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
    var summary: CostSummary
  }
}
