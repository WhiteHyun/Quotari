import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageObservationRootsTests {
  @Test func codexObservationRootsUseConfiguredHomeAndIncludeFutureDirectories() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-observation-roots-\(UUID().uuidString)", isDirectory: true)
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: root,
      cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)
    )

    #expect(estimator.usageInsightsObservationRoots(provider: .codex, account: nil) == [
      codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
      codexHome.appendingPathComponent("sessions", isDirectory: true),
    ])
  }

  @Test func capturedAccountHasNoLocalObservationRoots() {
    let estimator = LocalUsageCostEstimator(
      environment: [:],
      homeDirectory: FileManager.default.temporaryDirectory,
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("quotari-observation-cache-\(UUID().uuidString)")
    )
    let captured = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: nil,
      credentialSource: .quotariRegistry(id: "claude:saved")
    )

    #expect(estimator.usageInsightsObservationRoots(
      provider: .claude,
      account: captured
    ).isEmpty)
  }

  @Test func automaticClaudeObservationIncludesDesktopSessionRoots() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-claude-observation-\(UUID().uuidString)", isDirectory: true)
    let estimator = LocalUsageCostEstimator(
      environment: [:],
      homeDirectory: root,
      cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)
    )

    let observedPaths = Set(
      estimator.usageInsightsObservationRoots(provider: .claude, account: nil).map(\.path)
    )
    #expect(observedPaths.contains(
      root.appendingPathComponent(
        "Library/Application Support/Claude/local-agent-mode-sessions",
        isDirectory: true
      ).path
    ))
    #expect(observedPaths.contains(
      root.appendingPathComponent(
        "Library/Application Support/Claude/claude-code-sessions",
        isDirectory: true
      ).path
    ))
  }

  @Test func selectedDefaultClaudeAccountObservesTheEntireSharedRootFamily() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-shared-claude-observation-\(UUID().uuidString)", isDirectory: true)
    let account = ProviderAccount(
      provider: .claude,
      displayName: "Claude",
      detail: nil,
      credentialSource: .claudeCredentialsFile(
        path: root.appendingPathComponent(".claude/.credentials.json").path
      )
    )
    let estimator = LocalUsageCostEstimator(
      environment: [:],
      homeDirectory: root,
      cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)
    )

    let observedPaths = Set(
      estimator.usageInsightsObservationRoots(provider: .claude, account: account).map(\.path)
    )

    #expect(observedPaths.contains(
      root.appendingPathComponent(".claude/projects", isDirectory: true).path
    ))
    #expect(observedPaths.contains(
      root.appendingPathComponent(".config/claude/projects", isDirectory: true).path
    ))
  }

  @Test func observationRootsPreserveConfiguredSymlinkPaths() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-observation-symlink-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target", isDirectory: true)
    let link = root.appendingPathComponent("codex", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": link.path],
      homeDirectory: root,
      cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)
    )

    #expect(estimator.usageInsightsObservationRoots(provider: .codex, account: nil) == [
      link.appendingPathComponent("archived_sessions", isDirectory: true),
      link.appendingPathComponent("sessions", isDirectory: true),
    ])
  }
}
