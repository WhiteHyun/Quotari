import Foundation

extension LocalUsageCostScanner {
  func scanFile(
    _ file: URL,
    provider: UsageProvider,
    range: DayRange,
    parser: (FileHandle, String) -> LocalUsageFileParseOutcome
  ) -> LocalUsageFileParseOutcome {
    guard !Task.isCancelled else { return .cancelled }
    let timeZoneIdentifier = range.calendar.timeZone.identifier
    if let memoized = fileScanMemo?.scan(
      provider: provider,
      file: file,
      timeZoneIdentifier: timeZoneIdentifier
    ) {
      return .success(memoized.filtered(to: range))
    }
    guard let snapshot = LocalUsageFileSnapshot(url: file) else { return .failure }
    let fingerprint = snapshot.fingerprint
    let cacheIdentity = LocalUsageFileScanCacheIdentity(
      provider: provider,
      sourcePath: snapshot.sourcePath,
      fingerprint: fingerprint,
      timeZoneIdentifier: timeZoneIdentifier
    )
    if let cached = fileScanCache?.load(cacheIdentity) {
      onCacheLoaded?(file)
      guard let currentSnapshot = LocalUsageFileSnapshot(url: file) else {
        return .failure
      }
      guard currentSnapshot.fingerprint != fingerprint
        || currentSnapshot.sourcePath != snapshot.sourcePath
      else {
        fileScanMemo?.store(cached, provider: provider, file: file, identity: cacheIdentity)
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
        timeZoneIdentifier: range.calendar.timeZone.identifier
      )
      fileScanCache?.save(
        scan,
        identity: cacheIdentity
      )
      fileScanMemo?.store(scan, provider: provider, file: file, identity: cacheIdentity)
      return .success(scan.filtered(to: range))
    case .cancelled:
      return .cancelled
    case .failure:
      return .failure
    }
  }
}
