import Foundation

/// Reference `ProviderFetchStrategy` returning deterministic fake usage with no
/// network. Replace with real API/OAuth/web/CLI strategies.
struct MockFetchStrategy: ProviderFetchStrategy {
    let id: String
    let kind: ProviderFetchKind = .mock
    let make: @Sendable (UsageProvider, Date) -> UsageSnapshot

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try? await Task.sleep(for: .milliseconds(250))   // simulate latency
        return ProviderFetchResult(usage: make(context.provider, context.now), sourceLabel: "Mock")
    }
}

public enum MockProviders {
    public static let descriptors: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: .codex,
            metadata: .init(displayName: "Codex", accent: .init(0.063, 0.639, 0.498), supportsWeekly: true),  // OpenAI #10A37F
            pipeline: .init { _ in [MockFetchStrategy(id: "codex.mock", make: codex)] }
        ),
        ProviderDescriptor(
            id: .claude,
            metadata: .init(displayName: "Claude", accent: .init(0.851, 0.467, 0.341), supportsWeekly: true),  // Anthropic #D97757
            pipeline: .init { _ in [MockFetchStrategy(id: "claude.mock", make: claude)] }
        ),
        ProviderDescriptor(
            id: .glm,
            metadata: .init(displayName: "GLM", accent: .init(0.25, 0.55, 0.90), supportsWeekly: false),
            pipeline: .init { _ in [MockFetchStrategy(id: "glm.mock", make: glm)] }
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

    private static let codex: @Sendable (UsageProvider, Date) -> UsageSnapshot = { provider, now in
        UsageSnapshot(
            provider: provider,
            plan: "Pro 5x",
            account: "you@example.com",
            primary: window(.session, used: 73, resetInMinutes: 104, durationMinutes: 300, now: now),
            secondary: window(.weekly, used: 34, resetInMinutes: 8880, durationMinutes: 10080, now: now),
            extraWindows: [
                NamedWindow(title: "Codex Spark 5-hour",
                            window: window(.custom, used: 0, resetInMinutes: 300, durationMinutes: 300, now: now)),
                NamedWindow(title: "Codex Spark Weekly",
                            window: window(.custom, used: 1, resetInMinutes: 4260, durationMinutes: 10080, now: now)),
            ],
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
                NamedWindow(title: "Daily Routines",
                            window: RateWindow(kind: .custom, usedPercent: 0)),
                NamedWindow(title: "Fable only",
                            window: window(.custom, used: 100, resetInMinutes: 853, durationMinutes: 10080, now: now)),
            ],
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
