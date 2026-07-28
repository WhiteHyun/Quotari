import Darwin
import Foundation

struct LocalUsageFileFingerprint: Codable, Equatable, Sendable {
  let byteCount: Int64
  let modifiedAt: Date
  let statusChangedAt: Date
  let fileID: UInt64

  init?(url: URL) {
    let stream = url.withUnsafeFileSystemRepresentation {
      fopen($0, "r")
    }
    guard let stream else { return nil }
    defer { fclose(stream) }
    var metadata = stat()
    guard fstat(fileno(stream), &metadata) == 0 else { return nil }
    byteCount = metadata.st_size
    modifiedAt = Self.date(metadata.st_mtimespec)
    statusChangedAt = Self.date(metadata.st_ctimespec)
    fileID = metadata.st_ino
  }

  private static func date(_ value: timespec) -> Date {
    Date(
      timeIntervalSince1970: TimeInterval(value.tv_sec)
        + TimeInterval(value.tv_nsec) / 1_000_000_000
    )
  }
}

struct LocalUsageFileScanCache: @unchecked Sendable {
  static let schemaVersion = 3

  private let cacheDirectory: URL
  private let fileManager: FileManager

  init(cacheDirectory: URL, fileManager: FileManager = .default) {
    self.cacheDirectory = cacheDirectory
    self.fileManager = fileManager
  }

  func load(
    provider: UsageProvider,
    url: URL,
    fingerprint: LocalUsageFileFingerprint,
    timeZoneIdentifier: String
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
          entry.fingerprint == fingerprint,
          entry.timeZoneIdentifier == timeZoneIdentifier
    else { return nil }
    return entry.scan
  }

  func save(
    _ scan: LocalUsageFileScan,
    provider: UsageProvider,
    url: URL,
    fingerprint: LocalUsageFileFingerprint,
    timeZoneIdentifier: String
  ) {
    let entry = Entry(
      schemaVersion: Self.schemaVersion,
      provider: provider,
      sourcePath: canonicalPath(url),
      fingerprint: fingerprint,
      timeZoneIdentifier: timeZoneIdentifier,
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
    let timeZoneIdentifier: String
    let scan: LocalUsageFileScan
  }
}
