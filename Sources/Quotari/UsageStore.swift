import AppKit
import Observation
import QuotariCore
import SwiftUI

/// The app's single source of UI truth. `@Observable` so SwiftUI (and the
/// menu-bar label) update automatically. `@MainActor` so all mutable state is
/// serialized on the main thread — provider fetches run off-actor and their
/// (Sendable) results are applied back here.
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [UsageProvider: UsageSnapshot] = [:]
    private(set) var errors: [UsageProvider: String] = [:]
    private(set) var sourceLabels: [UsageProvider: String] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    /// Refresh cadence in seconds (tunable in Preferences).
    /// TODO: replace the fixed timer with an adaptive policy (fast when the
    /// popover was recently open, slow when idle / on low power).
    var refreshInterval: TimeInterval = 60 {
        didSet { startTimer() }
    }

    let providers: [ProviderDescriptor] = ProviderRegistry.all

    private var timerTask: Task<Void, Never>?

    init() {
        assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
        startTimer()
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }   // coalesce: one refresh at a time
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        await withTaskGroup(of: (UsageProvider, Result<ProviderFetchResult, Error>).self) { group in
            for descriptor in providers {
                group.addTask {
                    (descriptor.id, await descriptor.fetch(now: now))
                }
            }
            for await (provider, result) in group {
                apply(provider: provider, result: result)
            }
        }
        lastRefresh = Date()
    }

    private func apply(provider: UsageProvider, result: Result<ProviderFetchResult, Error>) {
        switch result {
        case .success(let value):
            snapshots[provider] = value.usage
            sourceLabels[provider] = value.sourceLabel
            errors[provider] = nil
        case .failure(let error):
            // Keep any prior snapshot (stale beats empty); just record the error.
            errors[provider] = error.localizedDescription
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }   // store gone → stop looping
                await self.refresh()
                let interval = self.refreshInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - Menu-bar icon

    var highestUsedPercent: Double {
        snapshots.values.map(\.highestUsedPercent).max() ?? 0
    }

    var menuBarIcon: NSImage {
        IconRenderer.gaugeIcon(
            usedPercent: highestUsedPercent,
            loading: isRefreshing && snapshots.isEmpty)
    }
}
