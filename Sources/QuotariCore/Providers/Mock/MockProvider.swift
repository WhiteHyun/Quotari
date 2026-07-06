import Foundation

/// Reference `ProviderFetchStrategy` returning deterministic fake usage with no
/// network. Replace with real API/OAuth/web/CLI strategies.
struct MockFetchStrategy: ProviderFetchStrategy {
    let id: String
    let kind: ProviderFetchKind = .mock
    let sessionUsed: Double
    let weeklyUsed: Double?
    let sessionResetInMinutes: Int

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try? await Task.sleep(for: .milliseconds(250))   // simulate latency

        let primary = RateWindow(
            kind: .session,
            usedPercent: sessionUsed,
            resetsAt: context.now.addingTimeInterval(Double(sessionResetInMinutes) * 60))

        let secondary = weeklyUsed.map { used in
            RateWindow(
                kind: .weekly,
                usedPercent: used,
                resetsAt: context.now.addingTimeInterval(7 * 24 * 3600))
        }

        let usage = UsageSnapshot(
            provider: context.provider,
            primary: primary,
            secondary: secondary,
            updatedAt: context.now)

        return ProviderFetchResult(usage: usage, sourceLabel: "Mock")
    }
}

public enum MockProviders {
    public static let descriptors: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: .codex,
            metadata: .init(displayName: "Codex", accent: .init(0.063, 0.639, 0.498), supportsWeekly: true),  // OpenAI #10A37F
            pipeline: .init { _ in
                [MockFetchStrategy(id: "codex.mock", sessionUsed: 82, weeklyUsed: 46, sessionResetInMinutes: 185)]
            }),
        ProviderDescriptor(
            id: .claude,
            metadata: .init(displayName: "Claude", accent: .init(0.851, 0.467, 0.341), supportsWeekly: true),  // Anthropic #D97757
            pipeline: .init { _ in
                [MockFetchStrategy(id: "claude.mock", sessionUsed: 31, weeklyUsed: 63, sessionResetInMinutes: 62)]
            }),
        ProviderDescriptor(
            id: .glm,
            metadata: .init(displayName: "GLM", accent: .init(0.25, 0.80, 0.55), supportsWeekly: false),
            pipeline: .init { _ in
                [MockFetchStrategy(id: "glm.mock", sessionUsed: 6, weeklyUsed: nil, sessionResetInMinutes: 300)]
            }),
    ]
}
