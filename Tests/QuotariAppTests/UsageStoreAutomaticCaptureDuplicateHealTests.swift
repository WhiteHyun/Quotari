import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

/// PS-209: multiple saved registry rows for the same verified Claude profile
/// used to block automatic management forever. Rows whose refresh token the
/// OAuth endpoint definitively rejected are now removed so the live login can
/// converge on one canonical saved row; anything less than that proof keeps
/// the fail-closed behavior.
@MainActor
struct AutomaticCaptureDuplicateHealTests {
  @Test func removesDeadDuplicatesAndRefreshesCanonicalRow() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:dead-old", token: "dead-old", capturedAt: Date(timeIntervalSince1970: 100)),
        SavedRowSpec(id: "claude:dead-new", token: "dead-new", capturedAt: Date(timeIntervalSince1970: 200)),
      ],
      reauthenticationRequiredIDs: ["claude:dead-old", "claude:dead-new"]
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    let remaining = fixture.registry.load().map(\.id)
    #expect(remaining == ["claude:dead-new"])
    guard case let .refreshClaude(id, _, _, _) = plans[fixture.candidate.id] else {
      Issue.record("Expected refreshClaude, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
    #expect(id == "claude:dead-new")
  }

  @Test func keepsBlockedWhenDuplicateSavedRowsAreBothPlausiblyAlive() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(
          id: "claude:alive-one",
          token: "alive-one",
          capturedAt: Date(timeIntervalSince1970: 100),
          expiresAt: Date().addingTimeInterval(3600)
        ),
        SavedRowSpec(
          id: "claude:alive-two",
          token: "alive-two",
          capturedAt: Date(timeIntervalSince1970: 200),
          expiresAt: Date().addingTimeInterval(3600)
        ),
      ],
      reauthenticationRequiredIDs: []
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    #expect(Set(fixture.registry.load().map(\.id)) == ["claude:alive-one", "claude:alive-two"])
    guard case let .blocked(message) = plans[fixture.candidate.id] else {
      Issue.record("Expected blocked, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
    #expect(message == "Multiple saved Claude accounts have the same verified profile.")
  }

  @Test func keepsExpiredDuplicateWithoutInvalidGrantProof() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:dead", token: "dead", capturedAt: Date(timeIntervalSince1970: 200)),
        SavedRowSpec(id: "claude:transient", token: "transient", capturedAt: Date(timeIntervalSince1970: 100)),
      ],
      reauthenticationRequiredIDs: ["claude:dead"],
      transientFailureIDs: ["claude:transient"]
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    // Only the invalid-grant row is removable; the transiently failing row may
    // still hold a working refresh token and becomes the canonical target.
    #expect(fixture.registry.load().map(\.id) == ["claude:transient"])
    guard case let .refreshClaude(id, _, _, _) = plans[fixture.candidate.id] else {
      Issue.record("Expected refreshClaude, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
    #expect(id == "claude:transient")
  }

  @Test func keepsBothExpiredDuplicatesOnTransientFailures() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:first", token: "first", capturedAt: Date(timeIntervalSince1970: 100)),
        SavedRowSpec(id: "claude:second", token: "second", capturedAt: Date(timeIntervalSince1970: 200)),
      ],
      reauthenticationRequiredIDs: [],
      transientFailureIDs: ["claude:first", "claude:second"]
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    #expect(Set(fixture.registry.load().map(\.id)) == ["claude:first", "claude:second"])
    guard case .blocked = plans[fixture.candidate.id] else {
      Issue.record("Expected blocked, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
  }

  @Test func removingDeadDuplicateDropsItsPinnedProfile() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:dead-old", token: "dead-old", capturedAt: Date(timeIntervalSince1970: 100)),
        SavedRowSpec(id: "claude:dead-new", token: "dead-new", capturedAt: Date(timeIntervalSince1970: 200)),
      ],
      reauthenticationRequiredIDs: ["claude:dead-old", "claude:dead-new"]
    )
    let removedSavedID = ProviderAccount.id(
      provider: .claude,
      source: .quotariRegistry(id: "claude:dead-old")
    )
    #expect(fixture.store.claudeProfiles[removedSavedID] != nil)

    _ = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    #expect(fixture.store.claudeProfiles[removedSavedID] == nil)
  }
}

private struct SavedRowSpec {
  let id: String
  let token: String
  let capturedAt: Date
  var expiresAt = Date(timeIntervalSince1970: 0)

  var accessToken: String { "\(token)-access" }
  var refreshToken: String { "\(token)-refresh" }
}

@MainActor
private struct DuplicateHealFixture {
  let registry: CapturedAccountStore
  let store: UsageStore
  let candidate: ProviderAccount
}

/// Every saved row and the live candidate verify to the same profile identity
/// ("acct"), reproducing the duplicate-saved-account state; per-row refresh
/// behavior is driven by the id sets.
@MainActor
private func makeDuplicateHealFixture(
  savedRows: [SavedRowSpec],
  reauthenticationRequiredIDs: Set<String>,
  transientFailureIDs: Set<String> = []
) throws -> DuplicateHealFixture {
  let registry = CapturedAccountStore.inMemoryForTesting()
  var pinnedProfiles: [String: ClaudeProfile] = [:]
  for row in savedRows {
    try registry.save(CapturedAccount(
      id: row.id,
      provider: .claude,
      displayName: "Claude Code",
      detail: "Saved in Quotari",
      capturedAt: row.capturedAt,
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(
        accessToken: row.accessToken,
        refreshToken: row.refreshToken,
        expiresAt: row.expiresAt
      )
    ))
    let savedID = ProviderAccount.id(provider: .claude, source: .quotariRegistry(id: row.id))
    pinnedProfiles[savedID] = ClaudeProfile(
      accountID: "acct",
      email: "dup@example.com",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: row.accessToken)
    )
  }
  let profileStore = ClaudeProfileStore.temporaryForTesting()
  try profileStore.save(pinnedProfiles)

  let livePayload = claudePayload(
    accessToken: "live-access",
    refreshToken: "live-refresh",
    expiresAt: Date().addingTimeInterval(3600)
  )
  let candidate = ProviderAccount(
    provider: .claude,
    displayName: "Live",
    detail: "Keychain",
    credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    credentialIdentity: "live-access"
  )
  let descriptor = ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in
      [DuplicateHealStrategy(
        reauthenticationRequiredIDs: reauthenticationRequiredIDs,
        transientFailureIDs: transientFailureIDs
      )]
    }
  )
  let store = UsageStore.isolatedForTesting(
    providers: [descriptor],
    accountCapture: AccountCaptureService(capturedAccounts: registry),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "live-access": ClaudeProfile(accountID: "acct", email: "dup@example.com"),
    ]),
    profileStore: profileStore,
    claudeCredentialLoader: { source in
      switch source {
      case .claudeKeychain:
        try? ClaudeCredentialsStore.parse(livePayload)
      case let .quotariRegistry(id):
        registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
      case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
        nil
      }
    },
    startsAutomatically: false
  )
  return DuplicateHealFixture(registry: registry, store: store, candidate: candidate)
}

/// Simulates the OAuth refresh outcome per saved registry row: a definitive
/// invalid grant for dead rows, a transient network failure for undecided
/// rows, and plain usage success otherwise.
private struct DuplicateHealStrategy: ProviderFetchStrategy {
  let id = "duplicate-heal"
  let kind = ProviderFetchKind.oauth
  let reauthenticationRequiredIDs: Set<String>
  let transientFailureIDs: Set<String>

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    if case let .quotariRegistry(registryID) = context.account?.credentialSource {
      if reauthenticationRequiredIDs.contains(registryID) {
        throw ClaudeTokenRefreshError.reauthenticationRequired
      }
      if transientFailureIDs.contains(registryID) {
        throw URLError(.notConnectedToInternet)
      }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Stub"
    )
  }
}
