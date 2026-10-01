import Darwin
import Foundation

/// Process-lifetime parse results keyed by enumerated path. An active CLI
/// session rewrites one log while thousands stay untouched, so a rescan
/// matches each file with a single `stat` instead of opening it and decoding
/// its on-disk cache entry. The fingerprint is the same one the disk cache
/// trusts, so a hit is exactly as fresh as a disk-cache hit.
final class LocalUsageFileScanMemo: @unchecked Sendable {
  private struct Key: Hashable {
    let provider: UsageProvider
    let path: String
  }

  private struct Entry {
    let fingerprint: LocalUsageFileFingerprint
    let sourcePath: String
    let timeZoneIdentifier: String
    let scan: LocalUsageFileScan
  }

  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]

  var count: Int {
    lock.withLock { entries.count }
  }

  var isEmpty: Bool {
    lock.withLock { entries.isEmpty }
  }

  func scan(
    provider: UsageProvider,
    file: URL,
    timeZoneIdentifier: String
  ) -> LocalUsageFileScan? {
    let key = Key(provider: provider, path: file.path)
    guard let entry = lock.withLock({ entries[key] }),
          entry.timeZoneIdentifier == timeZoneIdentifier,
          LocalUsageFileFingerprint(path: file.path) == entry.fingerprint,
          // A link retargeted to another name of the same inode keeps the fingerprint but changes the
          // session identity derived from the resolved path, so the path is revalidated too.
          Self.resolvedPath(file.path) == entry.sourcePath
    else { return nil }
    return entry.scan
  }

  func store(
    _ scan: LocalUsageFileScan,
    provider: UsageProvider,
    file: URL,
    identity: LocalUsageFileScanCacheIdentity
  ) {
    let entry = Entry(
      fingerprint: identity.fingerprint,
      sourcePath: identity.sourcePath,
      timeZoneIdentifier: identity.timeZoneIdentifier,
      scan: scan
    )
    lock.withLock { entries[Key(provider: provider, path: file.path)] = entry }
  }

  /// Matches `LocalUsageFileSnapshot.sourcePath`, which resolves through
  /// `F_GETPATH`; `realpath` keeps `/private` the way the descriptor path does.
  private static func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL.path
  }

  /// Drops entries the history window can no longer reach, which also bounds
  /// entries for deleted logs to one window.
  func prune(provider: UsageProvider, olderThan cutoff: Date) {
    lock.withLock {
      entries = entries.filter { key, entry in
        key.provider != provider || entry.fingerprint.modifiedAt >= cutoff
      }
    }
  }
}

extension LocalUsageFileFingerprint {
  /// Follows symlinks like `open` + `fstat`, so a retargeted link yields the
  /// target's device and inode and never matches the previous target's entry.
  init?(path: String) {
    var metadata = stat()
    guard stat(path, &metadata) == 0 else { return nil }
    self.init(metadata: metadata)
  }
}
