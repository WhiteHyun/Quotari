import CustomDump
import Foundation
@testable import QuotariCore
import Testing

@Suite(.serialized)
struct LocalUsageScopeIdentityStoreTests {
  @Test func sharedScopeCanonicalizesSymlinkedRoots() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let symlink = fixture.root.appendingPathComponent("codex-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.codexHome)
    let symlinkEstimator = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": symlink.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )

    let automatic = try #require(await symlinkEstimator.insights(
      provider: .codex,
      account: nil,
      now: fixture.now,
      historyDays: 30
    ))
    let selected = try #require(await fixture.estimator().insights(
      provider: .codex,
      account: fixture.codexAccount(identity: "account"),
      now: fixture.now,
      historyDays: 30
    ))

    expectNoDifference(automatic.scopeKey, selected.scopeKey)
  }

  @Test func removedAndRecreatedSymlinkCannotResurrectThePreviousCache() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let symlink = fixture.root.appendingPathComponent("codex-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.codexHome)
    let estimator = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": symlink.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )
    let initialScope = try #require(
      estimator.resolvedInsightsScope(provider: .codex, account: nil)
    )

    #expect(await estimator.insights(
      provider: .codex,
      account: nil,
      now: fixture.now,
      historyDays: 30
    ) != nil)
    try FileManager.default.removeItem(at: symlink)
    let emptyScope = try #require(
      estimator.resolvedInsightsScope(provider: .codex, account: nil)
    )
    let emptyOutcome = await estimator.costRefreshOutcome(
      provider: .codex,
      account: nil,
      now: fixture.now,
      historyDays: 30
    )
    expectNoDifference(emptyOutcome, .confirmedEmpty)

    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.codexHome)
    let recreatedScope = try #require(
      estimator.resolvedInsightsScope(provider: .codex, account: nil)
    )

    expectNoDifference(emptyScope, initialScope)
    expectNoDifference(recreatedScope, initialScope)
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: nil,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }

  @Test func separateIdentityStoresCannotDropAnotherAliasMapping() throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let firstAlias = fixture.root.appendingPathComponent("first-codex-link", isDirectory: true)
    let secondAlias = fixture.root.appendingPathComponent("second-codex-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: firstAlias,
      withDestinationURL: fixture.codexHome
    )
    let first = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": firstAlias.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )
    let second = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": secondAlias.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )

    _ = try #require(second.resolvedInsightsScope(provider: .codex, account: nil))
    let initialScope = try #require(
      first.resolvedInsightsScope(provider: .codex, account: nil)
    )
    try FileManager.default.createSymbolicLink(
      at: secondAlias,
      withDestinationURL: fixture.codexHome
    )
    _ = try #require(second.resolvedInsightsScope(provider: .codex, account: nil))
    try FileManager.default.removeItem(at: firstAlias)

    let relaunched = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": firstAlias.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )
    expectNoDifference(
      relaunched.resolvedInsightsScope(provider: .codex, account: nil),
      initialScope
    )
  }

  @Test func sameAliasWritersPreserveTheLatestResolvedTarget() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-scope-identity-race-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("cache", isDirectory: true)
    let oldTarget = directory.appendingPathComponent("old", isDirectory: true)
    let newTarget = directory.appendingPathComponent("new", isDirectory: true)
    let alias = directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: oldTarget, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newTarget, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: oldTarget)
    let hook = BlockingCacheMutationHook()
    let oldStore = LocalUsageScopeIdentityStore(
      cacheDirectory: cache,
      mutationHook: { hook.pause() }
    )
    let newStore = LocalUsageScopeIdentityStore(cacheDirectory: cache)

    let oldWrite = Task.detached {
      oldStore.identities(for: [alias])
    }
    await hook.waitUntilReached()
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: newTarget)
    let newWrite = Task.detached {
      newStore.identities(for: [alias])
    }
    hook.finish()
    _ = await oldWrite.value
    let newIdentity = await newWrite.value
    try FileManager.default.removeItem(at: alias)

    let relaunched = LocalUsageScopeIdentityStore(cacheDirectory: cache)
    expectNoDifference(relaunched.identities(for: [alias]), newIdentity)
  }
}
