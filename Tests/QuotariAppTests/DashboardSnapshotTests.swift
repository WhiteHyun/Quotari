import AppKit
@testable import Quotari
@testable import QuotariCore
import SwiftUI
import Testing

/// Renders the dashboard (with mock data) to light + dark PNGs for visual
/// review. Not an assertion of pixels — a convenience so `swift test` refreshes
/// the previews. Output goes to `$QUOTARI_SNAPSHOT_DIR` or `<package>/Snapshots`.
@MainActor
struct DashboardSnapshotTests {
  @Test func renderDashboardSnapshots() async throws {
    _ = NSApplication.shared
    // A deterministic estimator keeps CostSectionView in the render without
    // scanning the machine's real usage logs (mock provider cost is discarded,
    // so a null estimator would drop the section entirely).
    let store = UsageStore.isolatedForTesting(
      providers: MockProviders.descriptors,
      costEstimator: SnapshotCostEstimator()
    )
    for _ in 0 ..< 100 {
      if store.snapshots.count >= ProviderRegistry.all.count,
         store.snapshots.values.allSatisfy({ $0.cost != nil }) {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(store.snapshots.count == ProviderRegistry.all.count)
    #expect(store.snapshots.values.allSatisfy { $0.cost != nil })

    let outputDirectory = Self.outputDirectory()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for (name, appearance) in Self.appearances {
      let png = Self.renderPNG(store: store, appearance: appearance)
      let url = outputDirectory.appendingPathComponent("dashboard-\(name).png")
      try png.write(to: url)
      print("📸 dashboard-\(name).png → \(url.path)")
      #expect(png.count > 1000)
    }
  }

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
  private static func renderPNG(store: UsageStore, appearance: NSAppearance) -> Data {
    let hosting = NSHostingView(rootView:
      DashboardContent()
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
}
