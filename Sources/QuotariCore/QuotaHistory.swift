import Foundation

/// Identifies one quota window's readings for one account.
public struct QuotaSeriesKey: Codable, Hashable, Sendable {
  public var provider: UsageProvider
  public var accountID: String
  public var window: UsageWindowKind

  public init(provider: UsageProvider, accountID: String, window: UsageWindowKind) {
    self.provider = provider
    self.accountID = accountID
    self.window = window
  }
}

/// One live reading of a quota window. Only real readings are stored; gaps
/// stay gaps.
public struct QuotaObservation: Codable, Equatable, Sendable {
  public var usedPercent: Double
  public var resetsAt: Date?
  public var observedAt: Date

  public init(usedPercent: Double, resetsAt: Date?, observedAt: Date) {
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.observedAt = observedAt
  }
}

/// A bounded history of live quota readings.
public struct QuotaHistory: Codable, Equatable, Sendable {
  /// A weekly window plus a day of margin.
  public static let retention: TimeInterval = 8 * 86400
  /// Unchanged readings closer together than this add nothing to a burndown.
  public static let minimumSpacing: TimeInterval = 5 * 60

  private var series: [QuotaSeriesKey: [QuotaObservation]] = [:]

  public init() {}

  public func observations(for key: QuotaSeriesKey) -> [QuotaObservation] {
    series[key] ?? []
  }

  /// Readings that share the window's current reset time. Providers report
  /// reset times that drift by seconds within one cycle.
  public func currentCycle(for key: QuotaSeriesKey, resetsAt: Date?) -> [QuotaObservation] {
    guard let resetsAt else { return [] }
    return observations(for: key).filter {
      guard let observed = $0.resetsAt else { return false }
      return abs(observed.timeIntervalSince(resetsAt)) <= Self.resetTolerance
    }
  }

  static let resetTolerance: TimeInterval = 5 * 60

  public mutating func record(_ observation: QuotaObservation, for key: QuotaSeriesKey) {
    var readings = (series[key] ?? []).filter {
      observation.observedAt.timeIntervalSince($0.observedAt) < Self.retention
    }
    if let last = readings.last,
       last.usedPercent == observation.usedPercent,
       observation.observedAt.timeIntervalSince(last.observedAt) < Self.minimumSpacing {
      series[key] = readings
      return
    }
    readings.append(observation)
    series[key] = readings
  }
}

/// Reads a burndown out of quota history without inventing data.
public enum QuotaBurndown {
  /// Readings further apart than this are a gap (the Mac slept or fetches
  /// failed), never a straight line.
  public static let maximumGap: TimeInterval = 15 * 60

  public static func segments(_ readings: [QuotaObservation]) -> [[QuotaObservation]] {
    var segments: [[QuotaObservation]] = []
    for reading in readings {
      if let last = segments.last?.last,
         reading.observedAt.timeIntervalSince(last.observedAt) <= maximumGap {
        segments[segments.count - 1].append(reading)
      } else {
        segments.append([reading])
      }
    }
    return segments
  }

  /// Percent per second over the latest unbroken stretch within `lookback`, or
  /// nil when it spans less than `minimumSpan` or usage went down.
  public static func recentBurnRate(
    _ readings: [QuotaObservation],
    now: Date,
    lookback: TimeInterval,
    minimumSpan: TimeInterval
  ) -> Double? {
    guard let latest = segments(readings).last else { return nil }
    let recent = latest.filter { now.timeIntervalSince($0.observedAt) <= lookback }
    guard let first = recent.first, let last = recent.last else { return nil }
    let span = last.observedAt.timeIntervalSince(first.observedAt)
    let rise = last.usedPercent - first.usedPercent
    guard span >= minimumSpan, rise >= 0 else { return nil }
    return rise / span
  }
}

/// Persists quota history as JSON in Application Support. A missing or
/// unreadable file starts an empty history.
public struct QuotaHistoryStore: Sendable {
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
      .appendingPathComponent("QuotaHistory.json")
  }

  public func load() -> QuotaHistory {
    guard let data = try? Data(contentsOf: url),
          let history = try? JSONDecoder().decode(QuotaHistory.self, from: data)
    else { return QuotaHistory() }
    return history
  }

  public func save(_ history: QuotaHistory) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(history).write(to: url, options: .atomic)
  }
}
