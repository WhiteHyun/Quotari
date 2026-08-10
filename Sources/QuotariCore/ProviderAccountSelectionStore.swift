import Foundation

public struct ProviderAccountSelectionStore: Sendable {
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
      .appendingPathComponent("ProviderAccounts.json")
  }

  public func load() -> [UsageProvider: ProviderAccount] {
    (try? loadValidated()) ?? [:]
  }

  /// A missing file is a valid first-launch state. Existing data that cannot
  /// be read or decoded is surfaced so callers performing destructive
  /// migrations never replace an unknown durable selection with an empty map.
  public func loadValidated() throws -> [UsageProvider: ProviderAccount] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    return try payload.selections.reduce(into: [:]) { selections, selection in
      guard selections[selection.provider] == nil else {
        throw DecodingError.dataCorrupted(.init(
          codingPath: [],
          debugDescription: "Duplicate account selection for \(selection.provider.rawValue)"
        ))
      }
      selections[selection.provider] = selection.account
    }
  }

  public func save(_ selections: [UsageProvider: ProviderAccount]) throws {
    let payload = Payload(
      selections: selections
        .map { Selection(provider: $0.key, account: $0.value) }
        .sorted { $0.provider.rawValue < $1.provider.rawValue }
    )
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder.prettyStable.encode(payload)
    try data.write(to: url, options: [.atomic])
  }

  private struct Payload: Codable {
    var selections: [Selection]
  }

  private struct Selection: Codable {
    var provider: UsageProvider
    var account: ProviderAccount
  }
}

private extension JSONEncoder {
  static var prettyStable: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
