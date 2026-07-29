import Darwin
import Foundation

struct LocalUsageFileFingerprint: Codable, Equatable, Sendable {
  let byteCount: Int64
  let modifiedAt: Date
  let statusChangedAt: Date
  let deviceID: UInt64
  let fileID: UInt64

  init?(handle: FileHandle) {
    var metadata = stat()
    guard fstat(handle.fileDescriptor, &metadata) == 0 else { return nil }
    byteCount = metadata.st_size
    modifiedAt = Self.date(metadata.st_mtimespec)
    statusChangedAt = Self.date(metadata.st_ctimespec)
    deviceID = UInt64(metadata.st_dev)
    fileID = metadata.st_ino
  }

  private static func date(_ value: timespec) -> Date {
    Date(
      timeIntervalSince1970: TimeInterval(value.tv_sec)
        + TimeInterval(value.tv_nsec) / 1_000_000_000
    )
  }
}

final class LocalUsageFileSnapshot {
  let handle: FileHandle
  let fingerprint: LocalUsageFileFingerprint
  let sourcePath: String

  init?(url: URL) {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let fingerprint = LocalUsageFileFingerprint(handle: handle),
          let sourcePath = Self.sourcePath(handle: handle)
    else { return nil }
    self.handle = handle
    self.fingerprint = fingerprint
    self.sourcePath = sourcePath
  }

  deinit {
    try? handle.close()
  }

  private static func sourcePath(handle: FileHandle) -> String? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(handle.fileDescriptor, F_GETPATH, &path) == 0 else { return nil }
    let pathBytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard let sourcePath = String(bytes: pathBytes, encoding: .utf8) else { return nil }
    return URL(fileURLWithPath: sourcePath).standardizedFileURL.path
  }
}

struct LocalUsageFileScanCache: @unchecked Sendable {
  static let schemaVersion = 5

  private let cacheDirectory: URL
  private let fileManager: FileManager

  init(cacheDirectory: URL, fileManager: FileManager = .default) {
    self.cacheDirectory = cacheDirectory
    self.fileManager = fileManager
  }

  func load(
    provider: UsageProvider,
    sourcePath: String,
    fingerprint: LocalUsageFileFingerprint,
    timeZoneIdentifier: String
  ) -> LocalUsageFileScan? {
    let cacheURL = cacheURL(provider: provider, sourcePath: sourcePath)
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
      try? fileManager.removeItem(at: cacheURL)
      return nil
    }
    guard entry.schemaVersion == Self.schemaVersion,
          entry.provider == provider,
          entry.sourcePath == sourcePath,
          entry.fingerprint == fingerprint,
          entry.timeZoneIdentifier == timeZoneIdentifier
    else { return nil }
    return entry.scan
  }

  func save(
    _ scan: LocalUsageFileScan,
    provider: UsageProvider,
    sourcePath: String,
    fingerprint: LocalUsageFileFingerprint,
    timeZoneIdentifier: String
  ) {
    let entry = Entry(
      schemaVersion: Self.schemaVersion,
      provider: provider,
      sourcePath: sourcePath,
      fingerprint: fingerprint,
      timeZoneIdentifier: timeZoneIdentifier,
      scan: scan
    )
    guard let data = try? JSONEncoder().encode(entry) else { return }
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? data.write(
      to: cacheURL(provider: provider, sourcePath: sourcePath),
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
    cacheURL(provider: provider, sourcePath: canonicalPath(sourceURL))
  }

  private func cacheURL(provider: UsageProvider, sourcePath: String) -> URL {
    let pathHash = ProviderCredentialIdentity.fingerprint(of: sourcePath)
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
