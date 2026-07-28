import Foundation

struct LocalUsageFileFingerprint: Codable, Equatable, Sendable {
  let byteCount: Int64
  let modifiedAt: Date

  init?(url: URL, fileManager: FileManager) {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber,
          let modifiedAt = attributes[.modificationDate] as? Date
    else { return nil }
    byteCount = size.int64Value
    self.modifiedAt = modifiedAt
  }
}

struct LocalUsageFileScanCache: @unchecked Sendable {
  static let schemaVersion = 1

  private let cacheDirectory: URL
  private let fileManager: FileManager

  init(cacheDirectory: URL, fileManager: FileManager = .default) {
    self.cacheDirectory = cacheDirectory
    self.fileManager = fileManager
  }

  func load(
    provider: UsageProvider,
    url: URL,
    fingerprint: LocalUsageFileFingerprint
  ) -> LocalUsageFileScan? {
    let cacheURL = cacheURL(provider: provider, sourceURL: url)
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
      try? fileManager.removeItem(at: cacheURL)
      return nil
    }
    guard entry.schemaVersion == Self.schemaVersion,
          entry.provider == provider,
          entry.sourcePath == canonicalPath(url),
          entry.fingerprint == fingerprint
    else { return nil }
    return entry.scan
  }

  func save(
    _ scan: LocalUsageFileScan,
    provider: UsageProvider,
    url: URL,
    fingerprint: LocalUsageFileFingerprint
  ) {
    let entry = Entry(
      schemaVersion: Self.schemaVersion,
      provider: provider,
      sourcePath: canonicalPath(url),
      fingerprint: fingerprint,
      scan: scan
    )
    guard let data = try? JSONEncoder().encode(entry) else { return }
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? data.write(
      to: cacheURL(provider: provider, sourceURL: url),
      options: [.atomic]
    )
  }

  func prune(olderThan cutoff: Date) {
    guard let urls = try? fileManager.contentsOfDirectory(
      at: cacheDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return }
    for url in urls where url.pathExtension == "json" {
      guard !Task.isCancelled else { return }
      guard let data = try? Data(contentsOf: url),
            let entry = try? JSONDecoder().decode(Entry.self, from: data)
      else {
        try? fileManager.removeItem(at: url)
        continue
      }
      if entry.fingerprint.modifiedAt < cutoff
        || !fileManager.fileExists(atPath: entry.sourcePath) {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  func cacheURL(provider: UsageProvider, sourceURL: URL) -> URL {
    let pathHash = ProviderCredentialIdentity.fingerprint(of: canonicalPath(sourceURL))
    return cacheDirectory.appendingPathComponent(
      "v\(Self.schemaVersion)-\(provider.rawValue)-\(pathHash).json",
      isDirectory: false
    )
  }

  private func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private struct Entry: Codable {
    let schemaVersion: Int
    let provider: UsageProvider
    let sourcePath: String
    let fingerprint: LocalUsageFileFingerprint
    let scan: LocalUsageFileScan
  }
}
