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
    let outputDirectory = Self.outputDirectory()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for state in states {
      for (appearanceName, appearance) in Self.appearances {
        let png = Self.renderPNG(
          store: state.store,
          providerStatus: state.providerStatus,
          appearance: appearance
        )
        let filename = "dashboard-\(state.name)-\(appearanceName).png"
        let url = outputDirectory.appendingPathComponent(filename)
        try png.write(to: url)
        print("📸 \(filename) → \(url.path)")
        #expect(png.count > 1000)
      }
    }
  }

  private static func snapshotStates() async -> [DashboardSnapshotState] {
    let loadedStore = await makeLoadedStore()
    return await [
      DashboardSnapshotState(name: "loaded", store: loadedStore),
      DashboardSnapshotState(
        name: "status-issue",
        store: loadedStore,
        providerStatus: ProviderStatusController(initialStatuses: [.codex: statusIssueFixture])
      ),
      DashboardSnapshotState(name: "stale", store: makeStaleStore()),
      DashboardSnapshotState(name: "no-account", store: makeNoAccountStore()),
      DashboardSnapshotState(name: "error", store: makeErrorStore()),
    ]
  }

  @Test func renderProviderStatusDetailSnapshots() throws {
    _ = NSApplication.shared
    let outputDirectory = Self.outputDirectory()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let controller = ProviderStatusController(initialStatuses: [.codex: Self.statusIssueFixture])

    for (appearanceName, appearance) in Self.appearances {
      let png = Self.renderStatusPNG(controller: controller, appearance: appearance)
      let filename = "provider-status-issue-\(appearanceName).png"
      let url = outputDirectory.appendingPathComponent(filename)
      try png.write(to: url)
      print("📸 \(filename) → \(url.path)")
      #expect(png.count > 1000)
    }
  }

  private static func makeLoadedStore() async -> UsageStore {
    let suiteName = "DashboardSnapshotTests.quota-markers"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let notifications = QuotaNotificationController(
      center: QuotaNotificationCenterStub(status: .authorized),
      defaults: defaults
    )
    _ = await notifications.setNotificationsEnabled(true)
    let loadedStore = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      costEstimator: SnapshotCostEstimator(),
      defaults: defaults,
      quotaNotifications: notifications
    )
    for _ in 0 ..< 100 {
      if loadedStore.snapshots.count >= ProviderRegistry.all.count,
         ProviderRegistry.all.allSatisfy({
           loadedStore.usageInsightsState(for: $0.id).summary != nil
         }) {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(loadedStore.snapshots.count == ProviderRegistry.all.count)
    #expect(ProviderRegistry.all.allSatisfy {
      loadedStore.usageInsightsState(for: $0.id).summary != nil
    })
    return loadedStore
  }

  private static func makeStaleStore() async -> UsageStore {
    let staleStore = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .codex)],
      costEstimator: SnapshotCostEstimator()
    )
    for _ in 0 ..< 100 {
      if staleStore.usageInsightsState(for: .codex).summary != nil {
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
      providers: [ProviderFixtures.descriptor(for: .codex)],
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

  private static let statusIssueFixture = ProviderServiceStatus(
    provider: .codex,
    state: .partialOutage,
    updatedAt: Date(timeIntervalSince1970: 1_784_517_444),
    statusPageURL: UsageProvider.codex.statusPageURL,
    components: [
      ProviderStatusComponent(id: "codex-api", name: "Codex API", state: .partialOutage),
      ProviderStatusComponent(id: "codex-login", name: "Authentication", state: .operational),
    ],
    incident: ProviderStatusIncident(
      id: "codex-incident",
      name: "Elevated errors for Codex workflows",
      status: "identified",
      impact: "major",
      url: URL(string: "https://status.openai.com/incidents/codex-incident")!
    )
  )

  private static let appearances: [(name: String, appearance: NSAppearance)] = [
    ("light", NSAppearance(named: .aqua)!),
    ("dark", NSAppearance(named: .darkAqua)!),
  ]

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
    controller: ProviderStatusController,
    appearance: NSAppearance
  ) -> Data {
    let hosting = NSHostingView(rootView:
      ProviderStatusDetailView(
        descriptor: ProviderFixtures.descriptor(for: .codex),
        controller: controller
      )
      .background(Color(nsColor: .windowBackgroundColor)))
    hosting.appearance = appearance
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 10)
    hosting.layoutSubtreeIfNeeded()

    let height = max(hosting.fittingSize.height, 160)
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: height)
    let window = NSWindow(
      contentRect: NSRect(x: -30000, y: -30000, width: 300, height: height),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
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

@MainActor
private struct DashboardSnapshotState {
  let name: String
  let store: UsageStore
  let providerStatus: ProviderStatusController

  init(
    name: String,
    store: UsageStore,
    providerStatus: ProviderStatusController = ProviderStatusController()
  ) {
    self.name = name
    self.store = store
    self.providerStatus = providerStatus
  }
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
