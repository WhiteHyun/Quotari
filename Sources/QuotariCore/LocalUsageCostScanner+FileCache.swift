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
    if let cached = fileScanCache?.load(
      provider: provider,
      sourcePath: snapshot.sourcePath,
      fingerprint: fingerprint,
      timeZoneIdentifier: range.calendar.timeZone.identifier
    ) {
      onCacheLoaded?(file)
      guard let currentSnapshot = LocalUsageFileSnapshot(url: file) else {
        return .failure
      }
      guard currentSnapshot.fingerprint != fingerprint else {
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
      fileScanCache?.save(
        scan,
        provider: provider,
        sourcePath: snapshot.sourcePath,
        fingerprint: snapshot.fingerprint,
        timeZoneIdentifier: range.calendar.timeZone.identifier
      )
      return .success(scan.filtered(to: range))
    case .cancelled:
      return .cancelled
    case .failure:
      return .failure
    }
  }
}
