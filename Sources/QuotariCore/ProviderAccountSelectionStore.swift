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
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: payload.selections.map { ($0.provider, $0.account) })
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
