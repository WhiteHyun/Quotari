import Foundation

extension LocalUsageCostScanner {
  func scanFile(
    _ file: URL,
    provider: UsageProvider,
    range: DayRange,
    parser: (FileHandle, String) -> LocalUsageFileParseOutcome
  ) -> LocalUsageFileParseOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard let snapshot = LocalUsageFileSnapshot(url: file) else { return .failure }
    let fingerprint = snapshot.fingerprint
    let cacheIdentity = LocalUsageFileScanCacheIdentity(
      provider: provider,
      sourcePath: snapshot.sourcePath,
      fingerprint: fingerprint,
      timeZoneIdentifier: range.calendar.timeZone.identifier,
      scanRange: provider == .claude ? LocalUsageFileScanRange(range) : nil
    )
    if let cached = fileScanCache?.load(cacheIdentity) {
      onCacheLoaded?(file)
      guard let currentSnapshot = LocalUsageFileSnapshot(url: file) else {
        return .failure
      }
      guard currentSnapshot.fingerprint != fingerprint
        || currentSnapshot.sourcePath != snapshot.sourcePath
      else {
        return .success(cached.filtered(to: range))
      }
      return parseAndCacheFile(
        file,
        snapshot: currentSnapshot,
        provider: provider,
        range: range,
        parser: parser
      )
    }
    return parseAndCacheFile(
      file,
      snapshot: snapshot,
      provider: provider,
      range: range,
      parser: parser
    )
  }

  private func parseAndCacheFile(
    _ file: URL,
    snapshot: LocalUsageFileSnapshot,
    provider: UsageProvider,
    range: DayRange,
    parser: (FileHandle, String) -> LocalUsageFileParseOutcome
  ) -> LocalUsageFileParseOutcome {
    switch parser(snapshot.handle, snapshot.sourcePath) {
    case let .success(scan):
      guard !Task.isCancelled else { return .cancelled }
      onFileParsed?(file)
      let cacheIdentity = LocalUsageFileScanCacheIdentity(
        provider: provider,
        sourcePath: snapshot.sourcePath,
        fingerprint: snapshot.fingerprint,
        timeZoneIdentifier: range.calendar.timeZone.identifier,
        scanRange: provider == .claude ? LocalUsageFileScanRange(range) : nil
      )
      fileScanCache?.save(
        scan,
        identity: cacheIdentity
      )
      return .success(scan.filtered(to: range))
    case .cancelled:
      return .cancelled
    case .failure:
      return .failure
    }
  }
}
