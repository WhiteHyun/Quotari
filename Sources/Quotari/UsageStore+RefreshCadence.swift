import Foundation
import QuotariCore

extension UsageStore {
  var quotaReadings: [UsageProvider: [Double?]] {
    snapshots.mapValues { [$0.primary?.usedPercent, $0.secondary?.usedPercent] }
  }

  /// The wait before the next scheduled refresh. A rate limit backs off only
  /// the cycle that follows it.
  func nextRefreshInterval(quotaMoved: Bool) -> TimeInterval {
    defer { wasRateLimitedSinceLastCycle = false }
    let mode = refreshMode
    let isActive = mode == .adaptive
      && (quotaMoved || enabledProviderDescriptors.contains { cliActivityProbe($0.id) })
    return RefreshCadence.interval(
      base: refreshInterval,
      mode: mode,
      isActive: isActive,
      wasRateLimited: wasRateLimitedSinceLastCycle
    )
  }

  func noteFetchFailure(_ error: any Error) {
    if case ProviderHTTPError.rateLimited = error {
      wasRateLimitedSinceLastCycle = true
    }
  }

  static func hasActiveCLISession(_ provider: UsageProvider) -> Bool {
    let processes = (try? CLIActivityDetector().activeProcessRecords(for: provider)) ?? []
    return !processes.isEmpty
  }
}
