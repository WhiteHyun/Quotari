import Foundation

extension LocalUsageCostScanner {
  func scanFile(
    _ file: URL,
    provider: UsageProvider,
    range: DayRange,
    parser: (URL) -> LocalUsageFileParseOutcome
  ) -> LocalUsageFileParseOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard let fingerprint = LocalUsageFileFingerprint(url: file) else {
      return .failure
    }
    if let cached = fileScanCache?.load(
      provider: provider,
      url: file,
      fingerprint: fingerprint,
      timeZoneIdentifier: range.calendar.timeZone.identifier
    ) {
      onCacheLoaded?(file)
      guard let currentFingerprint = LocalUsageFileFingerprint(url: file) else {
        return .failure
      }
      guard currentFingerprint != fingerprint else {
        return .success(cached.filtered(to: range))
      }
      return parseAndCacheFile(
        file,
        provider: provider,
        range: range,
        fingerprint: currentFingerprint,
        parser: parser
      )
    }
    return parseAndCacheFile(
      file,
      provider: provider,
      range: range,
      fingerprint: fingerprint,
      parser: parser
    )
  }

  private func parseAndCacheFile(
    _ file: URL,
    provider: UsageProvider,
    range: DayRange,
    fingerprint: LocalUsageFileFingerprint,
    parser: (URL) -> LocalUsageFileParseOutcome
  ) -> LocalUsageFileParseOutcome {
    switch parser(file) {
    case let .success(scan):
      guard !Task.isCancelled else { return .cancelled }
      onFileParsed?(file)
      fileScanCache?.save(
        scan,
        provider: provider,
        url: file,
        fingerprint: fingerprint,
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
