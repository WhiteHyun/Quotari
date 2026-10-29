import AppKit
@testable import Quotari
@testable import QuotariCore
import SwiftUI
import Testing

@MainActor
struct AnalyticsWindowTests {
  @Test func reopeningFromAnotherCardReplacesTheWindowContext() throws {
    let store = UsageStore.isolatedForTesting(providers: ProviderRegistry.all, startsAutomatically: false)
    let controller = AnalyticsWindowController()
    defer { controller.close() }

    controller.show(store: store, context: AnalyticsContext(provider: .claude, period: .thirtyDays))
    let model = try #require(controller.model)
    model.context.accountID = "picked-in-window"
    controller.show(store: store, context: AnalyticsContext(provider: .codex, period: .sevenDays))

    #expect(controller.isVisible)
    #expect(controller.windowTitle == "Usage Analytics")
    #expect(controller.isResizable)
    let minimum = try #require(controller.minimumContentSize)
    #expect(minimum.width >= 680 && minimum.height >= 480)
    #expect(controller.model === model)
    #expect(model.context == AnalyticsContext(provider: .codex, period: .sevenDays))
  }

  /// Renders the window's content for visual review, like the dashboard
  /// snapshots.
  @Test func renderAnalyticsSnapshots() async throws {
    _ = NSApplication.shared
    let store = await DashboardSnapshotTests.makeLoadedStore()
    let directory = DashboardSnapshotTests.outputDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for (name, appearance) in DashboardSnapshotTests.appearances {
      let png = try Self.renderPNG(store: store, appearance: appearance)
      try png.write(to: directory.appendingPathComponent("analytics-claude-\(name).png"))
      #expect(png.count > 1000)
    }
  }

  private static func renderPNG(store: UsageStore, appearance: NSAppearance) throws -> Data {
    let model = AnalyticsWindowModel(context: AnalyticsContext(provider: .claude, period: .thirtyDays))
    let hosting = NSHostingView(rootView: AnalyticsRootView(model: model).environment(store))
    hosting.appearance = appearance
    hosting.frame = NSRect(x: 0, y: 0, width: 840, height: 1100)
    let window = NSWindow(
      contentRect: NSRect(x: -30000, y: -30000, width: 840, height: 1100),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.appearance = appearance
    window.contentView = hosting
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    defer { window.orderOut(nil) }
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    return try #require(rep.representation(using: .png, properties: [:]))
  }
}
