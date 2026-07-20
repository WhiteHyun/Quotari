import AppKit
@testable import Quotari
@testable import QuotariCore
import SwiftUI
import Testing

/// Renders loaded, stale, no-account, and fetch-error dashboard states to light
/// + dark PNGs for visual review. Not an assertion of pixels — a convenience so
/// `swift test` refreshes the previews. Output goes to `$QUOTARI_SNAPSHOT_DIR`
/// or `<package>/Snapshots`.
@MainActor
struct DashboardSnapshotTests {
  @Test func renderDashboardSnapshots() async throws {
    _ = NSApplication.shared
    let states = await Self.snapshotStates()
    let providerStatus = Self.providerStatusFixture()
    let outputDirectory = Self.outputDirectory()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for state in states {
      for (appearanceName, appearance) in Self.appearances {
        let png = Self.renderPNG(
          store: state.store,
          providerStatus: providerStatus,
          appearance: appearance
        )
        let filename = "dashboard-\(state.name)-\(appearanceName).png"
        let url = outputDirectory.appendingPathComponent(filename)
        try png.write(to: url)
        print("📸 \(filename) → \(url.path)")
        #expect(png.count > 1000)
      }
    }

    for (appearanceName, appearance) in Self.appearances {
      let png = Self.renderStatusPNG(
        providerStatus: providerStatus,
        appearance: appearance
      )
      let filename = "provider-status-\(appearanceName).png"
      let url = outputDirectory.appendingPathComponent(filename)
      try png.write(to: url)
      print("📸 \(filename) → \(url.path)")
      #expect(png.count > 1000)
    }
  }

  private static func snapshotStates() async -> [DashboardSnapshotState] {
    let loadedStore = await makeLoadedStore()
    return await [
      DashboardSnapshotState(name: "loaded", store: loadedStore),
      DashboardSnapshotState(name: "stale", store: makeStaleStore()),
      DashboardSnapshotState(name: "no-account", store: makeNoAccountStore()),
      DashboardSnapshotState(name: "error", store: makeErrorStore()),
    ]
  }

  private static func makeLoadedStore() async -> UsageStore {
    let loadedStore = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      costEstimator: SnapshotCostEstimator()
    )
    for _ in 0 ..< 100 {
      if loadedStore.snapshots.count >= ProviderRegistry.all.count,
         loadedStore.snapshots.values.allSatisfy({ $0.cost != nil }) {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(loadedStore.snapshots.count == ProviderRegistry.all.count)
    #expect(loadedStore.snapshots.values.allSatisfy { $0.cost != nil })
    return loadedStore
  }

  private static func makeStaleStore() async -> UsageStore {
    let staleStore = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptors[0]],
      costEstimator: SnapshotCostEstimator()
    )
    for _ in 0 ..< 100 {
      if staleStore.snapshots[.codex]?.cost != nil {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(staleStore.snapshots[.codex] != nil)
    staleStore.errors[.codex] = "The provider could not be reached."
    return staleStore
  }

  private static func makeNoAccountStore() async -> UsageStore {
    let noAccountStore = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptors[0]],
      startsAutomatically: false
    )
    await noAccountStore.reloadAccounts()
    #expect(noAccountStore.credentialDiscoveryState(for: .codex) == .absent)
    return noAccountStore
  }

  private static func makeErrorStore() async -> UsageStore {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Unavailable",
      detail: "auth.json",
      credentialSource: .codexAuthFile(path: "/tmp/codex/auth.json")
    )
    let errorStore = UsageStore.isolatedForTesting(
      providers: [Self.errorDescriptor],
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [account]]),
      startsAutomatically: false
    )
    await errorStore.reloadAccounts()
    await errorStore.refresh(provider: .codex)
    #expect(errorStore.snapshots[.codex] == nil)
    #expect(errorStore.errors[.codex] != nil)
    return errorStore
  }

  private static let errorDescriptor = ProviderDescriptor(
    id: .codex,
    metadata: ProviderRegistry.descriptor(for: .codex).metadata,
    pipeline: ProviderFetchPipeline { _ in [DashboardFailureStrategy()] }
  )

  private static let appearances: [(name: String, appearance: NSAppearance)] = [
    ("light", NSAppearance(named: .aqua)!),
    ("dark", NSAppearance(named: .darkAqua)!),
  ]

  private static func providerStatusFixture() -> ProviderStatusController {
    let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    return ProviderStatusController(initialStatuses: [
      .codex: ProviderServiceStatus(
        provider: .codex,
        state: .degradedPerformance,
        updatedAt: updatedAt,
        statusPageURL: .init(string: "https://status.openai.com/")!,
        components: [
          ProviderStatusComponent(
            id: "codex-desktop",
            name: "Codex in ChatGPT Desktop",
            state: .operational
          ),
          ProviderStatusComponent(
            id: "codex-api",
            name: "Codex API",
            state: .degradedPerformance
          ),
        ],
        incident: ProviderStatusIncident(
          id: "codex-incident",
          name: "Elevated errors for GitHub-dependent Codex workflows",
          status: "monitoring",
          impact: "minor",
          url: .init(string: "https://status.openai.com/incidents/codex-incident")!
        )
      ),
      .claude: ProviderServiceStatus(
        provider: .claude,
        state: .operational,
        updatedAt: updatedAt,
        statusPageURL: .init(string: "https://status.claude.com/")!,
        components: [
          ProviderStatusComponent(
            id: "claude-code",
            name: "Claude Code",
            state: .operational
          ),
          ProviderStatusComponent(
            id: "claude-api",
            name: "Claude API (api.anthropic.com)",
            state: .operational
          ),
        ]
      ),
    ])
  }

  private static func outputDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["QUOTARI_SNAPSHOT_DIR"], !dir.isEmpty {
      return URL(fileURLWithPath: dir, isDirectory: true)
    }
    // Walk up: this file → QuotariAppTests → Tests → package root.
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Snapshots", isDirectory: true)
  }

  private struct SnapshotCostEstimator: UsageCostEstimating {
    static let day = Date(timeIntervalSince1970: 1_783_478_400)

    func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
      CostSummary(
        todaySpend: 4.20,
        monthSpend: 38.75,
        monthTokens: 12_500_000,
        latestTokens: 48000,
        topModel: "gpt-5",
        sourceDescription: "Estimated from local logs",
        daily: (0 ..< 7).map { offset in
          DailyCost(
            date: Self.day.addingTimeInterval(TimeInterval(offset - 6) * 86400),
            spend: [1.10, 0.40, 2.30, 0.85, 3.10, 1.75, 4.20][offset],
            tokens: 250_000 * (offset + 1)
          )
        }
      )
    }
  }

  /// Renders in an off-screen NSWindow and captures via `cacheDisplay` (this
  /// draws the real view tree, including SF Symbols and vibrancy-less content).
  private static func renderPNG(
    store: UsageStore,
    providerStatus: ProviderStatusController,
    appearance: NSAppearance
  ) -> Data {
    let hosting = NSHostingView(rootView:
      DashboardContent(providerStatus: providerStatus)
        .environment(store)
        .background(Color(nsColor: .windowBackgroundColor)))
    hosting.appearance = appearance
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 10)
    hosting.layoutSubtreeIfNeeded()

    let height = max(hosting.fittingSize.height, 200)
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: height)

    let window = NSWindow(
      contentRect: NSRect(x: -30000, y: -30000, width: 300, height: height),
      styleMask: .borderless, backing: .buffered, defer: false
    )
    window.appearance = appearance
    window.isOpaque = true
    window.contentView = hosting
    window.orderFrontRegardless()

    // Pump the main run loop so AppKit/SwiftUI complete layout and display.
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    defer { window.orderOut(nil) }

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return Data() }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    return rep.representation(using: .png, properties: [:]) ?? Data()
  }

  private static func renderStatusPNG(
    providerStatus: ProviderStatusController,
    appearance: NSAppearance
  ) -> Data {
    let content = ProviderStatusPopover(
      descriptors: ProviderFixtures.descriptors,
      controller: providerStatus
    )
    let hosting = NSHostingView(rootView:
      content.background(Color(nsColor: .windowBackgroundColor)))
    hosting.appearance = appearance
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 10)
    hosting.layoutSubtreeIfNeeded()

    let height = max(hosting.fittingSize.height, 200)
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: height)
    let window = NSWindow(
      contentRect: NSRect(x: -30000, y: -30000, width: 300, height: height),
      styleMask: .borderless, backing: .buffered, defer: false
    )
    window.appearance = appearance
    window.isOpaque = true
    window.contentView = hosting
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    defer { window.orderOut(nil) }

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return Data() }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    return rep.representation(using: .png, properties: [:]) ?? Data()
  }
}

private struct DashboardSnapshotState {
  let name: String
  let store: UsageStore
}

private struct DashboardFailureStrategy: ProviderFetchStrategy {
  let id = "dashboard.failure"
  let kind = ProviderFetchKind.api

  func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
    throw DashboardFixtureError()
  }
}

private struct DashboardFixtureError: LocalizedError {
  var errorDescription: String? {
    "The provider could not be reached. Check your connection and try again."
  }
}
