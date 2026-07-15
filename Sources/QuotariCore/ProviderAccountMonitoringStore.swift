import Foundation

public struct ProviderAccountMonitoringStore: Sendable {
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
      .appendingPathComponent("MonitoredProviderAccounts.json")
  }

  /// A missing provider means the user has not configured monitoring yet.
  /// An explicitly persisted empty array means the user chose to monitor none.
  public func load() throws -> [UsageProvider: [ProviderAccount]] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    return try payload.selections.reduce(into: [:]) { selections, selection in
      guard selections[selection.provider] == nil else {
        throw DecodingError.dataCorrupted(.init(
          codingPath: [],
          debugDescription: "Duplicate monitoring selection for \(selection.provider.rawValue)"
        ))
      }
      selections[selection.provider] = selection.accounts
    }
  }

  public func save(_ selections: [UsageProvider: [ProviderAccount]]) throws {
    let payload = Payload(
      selections: selections
        .map { Selection(provider: $0.key, accounts: $0.value) }
        .sorted { $0.provider.rawValue < $1.provider.rawValue }
    )
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(payload).write(to: url, options: [.atomic])
  }

  private struct Payload: Codable {
    var selections: [Selection]
  }

  private struct Selection: Codable {
    var provider: UsageProvider
    var accounts: [ProviderAccount]
  }
}
