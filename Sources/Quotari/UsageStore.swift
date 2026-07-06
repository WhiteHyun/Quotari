import AppKit
import Observation
import QuotariCore
import SwiftUI

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [UsageProvider: UsageSnapshot] = [:]
    private(set) var errors: [UsageProvider: String] = [:]
    private(set) var sourceLabels: [UsageProvider: String] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    var refreshInterval: TimeInterval = 60 {
        didSet { startTimer() }
    }

    var iconStyle: MenuBarIconStyle = MenuBarIconStyle(rawValue: UserDefaults.standard.string(forKey: UsageStore.iconStyleKey) ?? "") ?? .gauge {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: Self.iconStyleKey)
        }
    }

    private static let iconStyleKey = "menuBarIconStyle"

    let providers: [ProviderDescriptor] = ProviderRegistry.all

    private var timerTask: Task<Void, Never>?

    init() {
        assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
        startTimer()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        await withTaskGroup(of: (UsageProvider, Result<ProviderFetchResult, Error>).self) { group in
            for descriptor in providers {
                group.addTask { (descriptor.id, await descriptor.fetch(now: now)) }
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
            errors[provider] = error.localizedDescription   // keep any prior snapshot
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refresh()
                let interval = self.refreshInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    var highestUsedPercent: Double {
        snapshots.values.map(\.highestUsedPercent).max() ?? 0
    }

    var menuBarIcon: NSImage {
        IconRenderer.gaugeIcon(
            usedPercent: highestUsedPercent,
            loading: isRefreshing && snapshots.isEmpty,
            style: iconStyle)
    }

    var menuBarAccessibilityLabel: String {
        guard !snapshots.isEmpty else { return "Quotari, loading usage" }
        let percent = Int(highestUsedPercent.rounded())
        return "Quotari, highest usage \(percent) percent, \(Theme.statusWord(highestUsedPercent))"
    }
}
