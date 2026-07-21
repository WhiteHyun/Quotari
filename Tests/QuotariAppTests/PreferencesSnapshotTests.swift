import AppKit
@testable import Quotari
@testable import QuotariCore
import SwiftUI
import Testing

@MainActor
struct PreferencesSnapshotTests {
  @Test func renderPreferencesSnapshots() async throws {
    _ = NSApplication.shared
    let accounts = Self.accounts
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      accountDiscovery: StaticAccountDiscovery(accounts: Dictionary(grouping: accounts, by: \.provider)),
      startsAutomatically: false
    )
    await store.reloadAccounts()
    accounts.forEach { store.setMonitoring(true, for: $0) }

    let outputDirectory = Self.outputDirectory()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for tab in PreferencesTab.allCases {
      for (name, appearance) in Self.appearances {
        let png = Self.renderPNG(store: store, selectedTab: tab, appearance: appearance)
        let filename = "preferences-\(tab.title.lowercased())-\(name).png"
        let url = outputDirectory.appendingPathComponent(filename)
        try png.write(to: url)
        print("📸 \(filename) → \(url.path)")
        #expect(png.count > 1000)
      }
    }
    for tab in [PreferencesTab.general, .accounts] {
      for (name, appearance) in Self.appearances {
        let png = Self.renderPNG(
          store: store,
          selectedTab: tab,
          appearance: appearance,
          size: NSSize(width: 980, height: 820)
        )
        let filename = "preferences-\(tab.title.lowercased())-expanded-\(name).png"
        let url = outputDirectory.appendingPathComponent(filename)
        try png.write(to: url)
        print("📸 \(filename) → \(url.path)")
        #expect(png.count > 1000)
      }
    }
  }

  private static let accounts = [
    ProviderAccount(
      provider: .claude,
      displayName: "Personal",
      detail: "personal@example.com",
      credentialSource: .claudeCredentialsFile(path: "/tmp/claude/.credentials.json")
    ),
    ProviderAccount(
      provider: .codex,
      displayName: "WhiteHyun",
      detail: "auth.json",
      credentialSource: .codexAuthFile(path: "/tmp/codex/auth.json")
    ),
    ProviderAccount(
      provider: .claude,
      displayName: "Team",
      detail: "team@example.com",
      credentialSource: .quotariRegistry(id: "claude-team")
    ),
  ]

  private static let appearances: [(name: String, appearance: NSAppearance)] = [
    ("light", NSAppearance(named: .aqua)!),
    ("dark", NSAppearance(named: .darkAqua)!),
  ]

  private static func outputDirectory() -> URL {
    if let directory = ProcessInfo.processInfo.environment["QUOTARI_SNAPSHOT_DIR"], !directory.isEmpty {
      return URL(fileURLWithPath: directory, isDirectory: true)
    }
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Snapshots", isDirectory: true)
  }

  private static func renderPNG(
    store: UsageStore,
    selectedTab: PreferencesTab,
    appearance: NSAppearance,
    size: NSSize = NSSize(width: 980, height: 680)
  ) -> Data {
    let hosting = NSHostingView(rootView:
      PreferencesView(selectedTab: selectedTab)
        .environment(store)
        .environment(\.appVersionInfo, AppVersionInfo(version: "0.1.2", build: "12")))
    hosting.appearance = appearance
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: size.width, height: size.height),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.appearance = appearance
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.contentView = hosting
    window.setContentSize(size)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    defer { window.orderOut(nil) }

    if ProcessInfo.processInfo.environment["QUOTARI_SNAPSHOT_SCREEN_CAPTURE"] == "1" {
      return screenCapture(window: window)
    }

    hosting.layoutSubtreeIfNeeded()
    guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      return Data()
    }
    hosting.cacheDisplay(in: hosting.bounds, to: representation)
    return representation.representation(using: .png, properties: [:]) ?? Data()
  }

  private static func screenCapture(window: NSWindow) -> Data {
    let captureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-settings-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: captureURL) }

    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", captureURL.path]
    do {
      try capture.run()
      capture.waitUntilExit()
      guard capture.terminationStatus == 0 else { return Data() }
      return try Data(contentsOf: captureURL)
    } catch {
      Issue.record("Could not capture Settings window: \(error)")
      return Data()
    }
  }
}
