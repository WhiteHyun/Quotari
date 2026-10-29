import Foundation

/// Daily usage kept after the session logs behind it are deleted, so history
/// outlives the CLIs' log retention. Days hold aggregates only: tokens, spend,
/// models, pricing coverage, and opaque session fingerprints, never prompts,
/// responses, or paths.
public struct DailyUsageArchive: Codable, Equatable, Sendable {
  /// A little over a year of days per scope.
  public static let retentionDays = 400

  private var scopes: [UsageInsightsScopeKey: [DailyUsageInsight]] = [:]

  public init() {}

  /// Days with activity, oldest first.
  public func days(for key: UsageInsightsScopeKey) -> [DailyUsageInsight] {
    scopes[key] ?? []
  }

  /// Keeps each active day of a fresh summary unless the archive already holds
  /// more tokens for it, which means logs behind that day were deleted since.
  /// Returns whether anything changed.
  @discardableResult
  public mutating func record(_ summary: UsageInsightsSummary) -> Bool {
    var days = Self.byDate(scopes[summary.scopeKey] ?? [])
    var changed = false
    for day in summary.daily where day.hasActivity {
      if let kept = days[day.date], kept.totalTokens > day.totalTokens {
        continue
      }
      if days[day.date] != day {
        days[day.date] = day
        changed = true
      }
    }
    let cutoff = summary.generatedAt.addingTimeInterval(-Double(Self.retentionDays) * 86400)
    let retained = days.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    guard changed || retained.count != days.count else { return false }
    scopes[summary.scopeKey] = retained
    return true
  }

  /// The summary with days whose logs were deleted filled back in.
  public func restoring(_ summary: UsageInsightsSummary) -> UsageInsightsSummary {
    let archived = Self.byDate(days(for: summary.scopeKey))
    guard !archived.isEmpty else { return summary }
    var restored = summary
    restored.daily = summary.daily.map { day in
      guard let kept = archived[day.date], kept.totalTokens > day.totalTokens else { return day }
      return kept
    }
    return restored
  }

  private static func byDate(_ days: [DailyUsageInsight]) -> [Date: DailyUsageInsight] {
    Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest })
  }
}

extension DailyUsageInsight {
  var totalTokens: Int {
    tokens.total.value ?? 0
  }

  var hasActivity: Bool {
    totalTokens > 0 || (spend.value ?? 0) > 0 || (sessionCount.value ?? 0) > 0
  }
}

/// Persists the archive as JSON in Application Support. A missing or
/// unreadable file starts an empty archive.
public struct DailyUsageArchiveStore: Sendable {
  public let url: URL

  public init(url: URL = Self.defaultURL()) {
    self.url = url
  }

  public static func defaultURL(
    fileManager: FileManager = .default,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? home.appendingPathComponent("Library/Application Support")
    return applicationSupport
      .appendingPathComponent("Quotari", isDirectory: true)
      .appendingPathComponent("DailyUsage.json")
  }

  public func load() -> DailyUsageArchive {
    guard let data = try? Data(contentsOf: url),
          let archive = try? JSONDecoder().decode(DailyUsageArchive.self, from: data)
    else { return DailyUsageArchive() }
    return archive
  }

  public func save(_ archive: DailyUsageArchive) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(archive).write(to: url, options: .atomic)
  }
}
