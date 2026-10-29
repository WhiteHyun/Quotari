import Foundation

/// The latest live usage that Quotari shares with other tools, such as the
/// `quotari` CLI. It holds no tokens or account identities (ADR 0003).
public struct SharedUsageSnapshot: Codable, Equatable, Sendable {
  /// Bumped only for changes that older readers would misread. New optional
  /// fields keep the version.
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var generatedAt: Date
  public var providers: [Provider]

  public init(generatedAt: Date, providers: [Provider]) {
    schemaVersion = Self.currentSchemaVersion
    self.generatedAt = generatedAt
    self.providers = providers
  }

  public struct Provider: Codable, Equatable, Sendable {
    /// `claude` or `codex`.
    public var id: String
    public var name: String
    public var plan: String?
    /// When this provider's readings were fetched.
    public var updatedAt: Date
    public var windows: [Window]

    public init(id: String, name: String, plan: String?, updatedAt: Date, windows: [Window]) {
      self.id = id
      self.name = name
      self.plan = plan
      self.updatedAt = updatedAt
      self.windows = windows
    }
  }

  public struct Window: Codable, Equatable, Sendable {
    /// `session`, `weekly`, or `custom`.
    public var kind: String
    /// Names a provider-specific limit beyond session and weekly.
    public var label: String?
    public var usedPercent: Double
    public var remainingPercent: Double
    public var resetsAt: Date?
    public var durationSeconds: Double?

    public init(
      kind: String,
      label: String? = nil,
      usedPercent: Double,
      resetsAt: Date? = nil,
      durationSeconds: Double? = nil
    ) {
      self.kind = kind
      self.label = label
      self.usedPercent = usedPercent
      remainingPercent = max(0, 100 - usedPercent)
      self.resetsAt = resetsAt
      self.durationSeconds = durationSeconds
    }
  }
}

public enum SharedUsageSnapshotReading: Equatable, Sendable {
  case missing
  case unreadable
  /// Written by a newer Quotari than this reader understands.
  case newerVersion(Int)
  case snapshot(SharedUsageSnapshot)
}

/// The snapshot file in Application Support. The app writes it; readers never
/// need anything else.
public struct SharedUsageSnapshotFile: Sendable {
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
      .appendingPathComponent("UsageSnapshot.json")
  }

  public func read() -> SharedUsageSnapshotReading {
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    guard let data = try? Data(contentsOf: url),
          let header = try? Self.decoder().decode(Header.self, from: data)
    else { return .unreadable }
    guard header.schemaVersion <= SharedUsageSnapshot.currentSchemaVersion else {
      return .newerVersion(header.schemaVersion)
    }
    guard let snapshot = try? Self.decoder().decode(SharedUsageSnapshot.self, from: data) else {
      return .unreadable
    }
    return .snapshot(snapshot)
  }

  public func write(_ snapshot: SharedUsageSnapshot) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Self.encode(snapshot).write(to: url, options: .atomic)
  }

  /// Pretty-printed with sorted keys and ISO 8601 dates, so other tools can
  /// read it without Quotari's conventions.
  public static func encode(_ snapshot: SharedUsageSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(snapshot)
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private struct Header: Decodable {
    var schemaVersion: Int
  }
}
