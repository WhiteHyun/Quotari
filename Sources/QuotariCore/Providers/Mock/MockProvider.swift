import Foundation

/// A deterministic mock strategy: returns fixed fake usage so the whole
/// pipeline + UI runs with no network. This is the reference implementation of
/// `ProviderFetchStrategy` — replace it (or add alongside it) with real
/// API/OAuth/web/CLI strategies as you build them.
struct MockFetchStrategy: ProviderFetchStrategy {
    let id: String
    let kind: ProviderFetchKind = .mock
    let sessionUsed: Double
    let weeklyUsed: Double?
    let sessionResetInMinutes: Int

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Simulate latency so the loading state is observable in the UI.
        try? await Task.sleep(for: .milliseconds(250))

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

/// Three demo providers with different usage levels so the dashboard and the
/// menu-bar gauge have realistic variety to design against:
///   - cortex: near limit (red gauge)
///   - nimbus: mid usage
///   - loom:   low usage, no weekly window
public enum MockProviders {
    public static let descriptors: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: .cortex,
            metadata: .init(displayName: "Cortex", accent: .init(0.40, 0.45, 0.95), supportsWeekly: true),
            pipeline: .init { _ in
                [MockFetchStrategy(id: "cortex.mock", sessionUsed: 82, weeklyUsed: 46, sessionResetInMinutes: 185)]
            }),
        ProviderDescriptor(
            id: .nimbus,
            metadata: .init(displayName: "Nimbus", accent: .init(0.95, 0.55, 0.25), supportsWeekly: true),
            pipeline: .init { _ in
                [MockFetchStrategy(id: "nimbus.mock", sessionUsed: 31, weeklyUsed: 63, sessionResetInMinutes: 62)]
            }),
        ProviderDescriptor(
            id: .loom,
            metadata: .init(displayName: "Loom", accent: .init(0.25, 0.80, 0.55), supportsWeekly: false),
            pipeline: .init { _ in
                [MockFetchStrategy(id: "loom.mock", sessionUsed: 6, weeklyUsed: nil, sessionResetInMinutes: 300)]
            }),
    ]
}
