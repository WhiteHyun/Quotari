import AppKit
import SwiftUI
import Testing
@testable import Quotari
@testable import QuotariCore

/// Renders the dashboard (with mock data) to light + dark PNGs for visual
/// review. Not an assertion of pixels — a convenience so `swift test` refreshes
/// the previews. Output goes to `$QUOTARI_SNAPSHOT_DIR` or `<package>/Snapshots`.
@MainActor
@Suite struct DashboardSnapshotTests {
    @Test func renderDashboardSnapshots() async throws {
        _ = NSApplication.shared
        let store = UsageStore()
        for _ in 0 ..< 100 {
            if store.snapshots.count >= ProviderRegistry.all.count { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.snapshots.count == ProviderRegistry.all.count)

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

    /// Renders in an off-screen NSWindow and captures via `cacheDisplay` (this
    /// draws the real view tree, including SF Symbols and vibrancy-less content).
    private static func renderPNG(store: UsageStore, appearance: NSAppearance) -> Data {
        let hosting = NSHostingView(rootView:
            DashboardView()
                .environment(store)
                .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = appearance
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 10)
        hosting.layoutSubtreeIfNeeded()

        let height = max(hosting.fittingSize.height, 200)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: height)

        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 300, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
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
