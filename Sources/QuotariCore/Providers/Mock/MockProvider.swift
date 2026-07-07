import Foundation

/// A `ProviderFetchStrategy` returning deterministic fake usage with no
/// network — used as demo/fallback data when no real credentials are present.
public struct MockFetchStrategy: ProviderFetchStrategy {
  public let id: String
  public let kind: ProviderFetchKind = .mock
  let make: @Sendable (UsageProvider, Date) -> UsageSnapshot

  public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    try? await Task.sleep(for: .milliseconds(250)) // simulate latency
    return ProviderFetchResult(usage: make(context.provider, context.now), sourceLabel: "Mock")
  }
}

public enum MockProviders {
  public static let codexStrategy = MockFetchStrategy(id: "codex.mock", make: codex)
  public static let claudeStrategy = MockFetchStrategy(id: "claude.mock", make: claude)
  public static let glmStrategy = MockFetchStrategy(id: "glm.mock", make: glm)

  public static let descriptors: [ProviderDescriptor] = [
    ProviderDescriptor(
      id: .codex,
      metadata: .init(
        displayName: "Codex",
        accent: .init(0.063, 0.639, 0.498),
        supportsWeekly: true
      ), // OpenAI #10A37F
      pipeline: .init { _ in [codexStrategy] }
    ),
    ProviderDescriptor(
      id: .claude,
      metadata: .init(
        displayName: "Claude",
        accent: .init(0.851, 0.467, 0.341),
        supportsWeekly: true
      ), // Anthropic #D97757
      pipeline: .init { _ in [claudeStrategy] }
    ),
    ProviderDescriptor(
      id: .glm,
      metadata: .init(displayName: "GLM", accent: .init(0.25, 0.55, 0.90), supportsWeekly: false),
      pipeline: .init { _ in [glmStrategy] }
    ),
  ]

  private static func window(
    _ kind: UsageWindowKind, used: Double, resetInMinutes: Double?, durationMinutes: Double, now: Date
  ) -> RateWindow {
    RateWindow(
      kind: kind,
      usedPercent: used,
      resetsAt: resetInMinutes.map { now.addingTimeInterval($0 * 60) },
      duration: durationMinutes * 60
    )
  }

  /// Deterministic 30-day cost series: a calm baseline with a couple of spikes,
  /// varied by `seed` so providers differ. Costs roughly $2000/M tokens.
  private static func cost(seed: Double, now: Date) -> CostSummary {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: now)
    var daily: [DailyCost] = []
    for offset in stride(from: 29, through: 0, by: -1) {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
      let phase = Double(29 - offset)
      let base = 8 + 6 * sin(phase / 3 + seed)
      let spike = (Int(phase + seed) % 9 == 0) ? 30.0 : 0
      let spend = max(0.5, base + spike)
      daily.append(DailyCost(date: day, spend: spend, tokens: Int(spend * 1_060_000)))
    }
    let month = daily.reduce(0) { $0 + $1.spend }
    return CostSummary(
      todaySpend: daily.last?.spend ?? 0,
      monthSpend: month,
      monthTokens: daily.reduce(0) { $0 + $1.tokens },
      latestTokens: daily.last?.tokens ?? 0,
      topModel: seed < 1 ? "gpt-5.5" : "claude-opus-4",
      daily: daily
    )
  }

  private static let codex: @Sendable (UsageProvider, Date) -> UsageSnapshot = { provider, now in
    UsageSnapshot(
      provider: provider,
      plan: "Pro 5x",
      account: "you@example.com",
      primary: window(.session, used: 73, resetInMinutes: 104, durationMinutes: 300, now: now),
      secondary: window(.weekly, used: 34, resetInMinutes: 8880, durationMinutes: 10080, now: now),
      extraWindows: [
        NamedWindow(
          title: "Codex Spark 5-hour",
          window: window(.custom, used: 0, resetInMinutes: 300, durationMinutes: 300, now: now)
        ),
        NamedWindow(
          title: "Codex Spark Weekly",
          window: window(.custom, used: 1, resetInMinutes: 4260, durationMinutes: 10080, now: now)
        ),
      ],
      cost: cost(seed: 0.3, now: now),
      updatedAt: now
    )
  }

  private static let claude: @Sendable (UsageProvider, Date) -> UsageSnapshot = { provider, now in
    UsageSnapshot(
      provider: provider,
      plan: "Team",
      account: "team@example.com",
      primary: window(.session, used: 32, resetInMinutes: 223, durationMinutes: 300, now: now),
      secondary: window(.weekly, used: 76, resetInMinutes: 853, durationMinutes: 10080, now: now),
      extraWindows: [
        NamedWindow(
          title: "Daily Routines",
          window: RateWindow(kind: .custom, usedPercent: 0)
        ),
        NamedWindow(
          title: "Fable only",
          window: window(.custom, used: 100, resetInMinutes: 853, durationMinutes: 10080, now: now)
        ),
      ],
      cost: cost(seed: 2.1, now: now),
      updatedAt: now
    )
  }

  private static let glm: @Sendable (UsageProvider, Date) -> UsageSnapshot = { provider, now in
    UsageSnapshot(
      provider: provider,
      plan: "Free",
      primary: window(.session, used: 6, resetInMinutes: 240, durationMinutes: 300, now: now),
      updatedAt: now
    )
  }
}
