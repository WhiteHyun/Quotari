import Foundation
@testable import QuotariCore

/// Deterministic usage fixtures available only to the app test target.
/// Production descriptors always resolve live OAuth strategies.
enum ProviderFixtures {
  static let descriptors: [ProviderDescriptor] = UsageProvider.allCases.map { provider in
    ProviderDescriptor(
      id: provider,
      metadata: ProviderRegistry.descriptor(for: provider).metadata,
      pipeline: ProviderFetchPipeline { _ in [FixtureUsageStrategy()] }
    )
  }
}

private struct FixtureUsageStrategy: ProviderFetchStrategy {
  let id = "test.fixture"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let snapshot = switch context.provider {
    case .codex:
      UsageSnapshot(
        provider: .codex,
        plan: "Pro 5x",
        account: "preview@example.com",
        primary: window(.session, used: 73, resetIn: 104 * 60, duration: 5 * 3600, now: context.now),
        secondary: window(.weekly, used: 34, resetIn: 6 * 86400, duration: 7 * 86400, now: context.now),
        updatedAt: context.now
      )
    case .claude:
      UsageSnapshot(
        provider: .claude,
        plan: "Max 20x",
        account: "team@example.com",
        primary: window(.session, used: 32, resetIn: 223 * 60, duration: 5 * 3600, now: context.now),
        secondary: window(.weekly, used: 76, resetIn: 4 * 86400, duration: 7 * 86400, now: context.now),
        updatedAt: context.now
      )
    }
    return ProviderFetchResult(
      usage: snapshot,
      sourceLabel: "Fixture",
      sourceKind: kind
    )
  }

  private func window(
    _ kind: UsageWindowKind,
    used: Double,
    resetIn: TimeInterval,
    duration: TimeInterval,
    now: Date
  ) -> RateWindow {
    RateWindow(
      kind: kind,
      usedPercent: used,
      resetsAt: now.addingTimeInterval(resetIn),
      duration: duration
    )
  }
}
