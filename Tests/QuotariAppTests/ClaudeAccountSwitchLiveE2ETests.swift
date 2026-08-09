import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

private let runsClaudeAccountSwitchLiveE2E =
  ProcessInfo.processInfo.environment["QUOTARI_RUN_CLAUDE_SWITCH_E2E"] == "1"

@MainActor
@Suite(.serialized)
struct ClaudeAccountSwitchLiveE2ETests {
  @Test(.enabled(if: runsClaudeAccountSwitchLiveE2E))
  func switchUsageFetchAndFreshCLIAuthenticationRoundTrip() async throws {
    let environment = ProcessInfo.processInfo.environment
    let targetID = try requiredEnvironment("QUOTARI_E2E_CLAUDE_TARGET_ID", in: environment)
    let claudeExecutable = try claudeExecutableURL(environment: environment)
    try requireQuotariIsNotRunning()

    let detector = CLIActivityDetector()
    try requireClaudeIsNotRunning(detector)

    let registry = CapturedAccountStore()
    let accountsBefore = try registry.registeredAccounts(for: .claude)
    let idsBefore = Set(accountsBefore.map(\.id))
    let target = try selectedTarget(id: targetID, from: accountsBefore)
    let targetIdentity = try requiredStrongTargetIdentity(for: target)

    let originalCredentials = try ClaudeCredentialsStore.loadResolved(environment: environment)
    if case .claudeEnvironment = originalCredentials.source {
      throw ClaudeSwitchLiveE2EError.environmentCredentialUnsupported
    }
    try await runRoundTrip(ClaudeSwitchLiveE2EContext(
      registry: registry,
      idsBefore: idsBefore,
      target: target,
      targetIdentity: targetIdentity,
      originalCredentials: originalCredentials,
      claudeExecutable: claudeExecutable,
      detector: detector,
      environment: environment
    ))
  }

  private func runRoundTrip(_ context: ClaudeSwitchLiveE2EContext) async throws {
    let original = try await originalAccountState(context)
    let store = makeLiveStore(registry: context.registry, detector: context.detector)
    var primaryError: Error?
    do {
      try await exerciseTargetAccount(context, store: store)
    } catch {
      primaryError = error
    }

    do {
      try await restoreAndCleanUp(context, original: original, store: store)
    } catch {
      if let primaryError {
        throw ClaudeSwitchLiveE2EError.restorationFailedAfterTestFailure(
          test: primaryError.localizedDescription,
          restoration: error.localizedDescription
        )
      }
      throw error
    }
    if let primaryError {
      throw primaryError
    }
  }

  private func originalAccountState(
    _ context: ClaudeSwitchLiveE2EContext
  ) async throws -> ClaudeOriginalAccountState {
    let originalCredentials = try await refreshedOriginalClaudeCredentialsIfNeeded(
      context.originalCredentials
    )
    let originalFingerprint = ProviderCredentialIdentity.fingerprint(
      of: originalCredentials.credentials.accessToken
    )
    var originalProfile = try await ClaudeProfileFetcher().fetchProfile(
      accessToken: originalCredentials.credentials.accessToken
    )
    originalProfile.fingerprint = originalFingerprint
    guard originalProfile.hasStrongAccountIdentity else {
      throw ClaudeSwitchLiveE2EError.originalIdentityUnavailable
    }
    guard !stronglyMatches(context.targetIdentity, profile: originalProfile) else {
      throw ClaudeSwitchLiveE2EError.targetIsCurrentAccount
    }

    let initialStatus = try claudeAuthStatus(executable: context.claudeExecutable)
    guard initialStatus.matches(profile: originalProfile) else {
      throw ClaudeSwitchLiveE2EError.initialCLIIdentityMismatch
    }
    let originalIdentity = ProviderCredentialIdentity.claudeIdentity(
      refreshToken: originalCredentials.credentials.refreshToken,
      accessToken: originalCredentials.credentials.accessToken
    )
    guard let originalIdentity else {
      throw ClaudeSwitchLiveE2EError.originalIdentityUnavailable
    }
    return ClaudeOriginalAccountState(identity: originalIdentity, profile: originalProfile)
  }

  private func exerciseTargetAccount(
    _ context: ClaudeSwitchLiveE2EContext,
    store: UsageStore
  ) async throws {
    await store.reloadAccounts()
    guard let targetAccount = store.accounts[.claude]?.first(where: {
      $0.credentialSource == .quotariRegistry(id: context.target.id)
    }) else {
      throw ClaudeSwitchLiveE2EError.targetNotSwitchable
    }

    await store.switchCLIAccount(to: targetAccount)
    guard store.captureErrors[.claude] == nil else {
      throw ClaudeSwitchLiveE2EError.switchFailed
    }
    await store.selectionRefreshTasks[.claude]?.value
    try verifyUsageFetch(store, targetID: context.target.id)
    try await verifyTargetAuthentication(context)
  }

  private func makeLiveStore(
    registry: CapturedAccountStore,
    detector: CLIActivityDetector
  ) -> UsageStore {
    UsageStore.isolatedForTesting(
      providers: [ProviderRegistry.descriptor(for: .claude)],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: ProviderAccountDiscovery(capturedAccounts: registry),
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      automaticallyCapturesDiscoveredAccounts: false,
      accountSwitch: AccountSwitchService(
        capturedAccounts: registry,
        activeCLIProcesses: detector.activeProcesses
      ),
      profileFetcher: ClaudeProfileFetcher(),
      claudeCredentialLoader: { source in
        try? ClaudeCredentialsStore.load(source: source, capturedAccounts: registry)
      },
      startsAutomatically: false
    )
  }

  private func verifyUsageFetch(_ store: UsageStore, targetID: String) throws {
    guard let selected = store.selectedAccounts[.claude] else {
      throw ClaudeSwitchLiveE2EError.postSwitchSelectionInvalid("The post-switch live Claude account was not selected.")
    }
    guard let origin = store.reconciledSelectionOrigins[.claude] else {
      throw ClaudeSwitchLiveE2EError
        .postSwitchSelectionInvalid("The post-switch selection lost its saved-account origin.")
    }
    guard origin.credentialSource == .quotariRegistry(id: targetID) else {
      throw ClaudeSwitchLiveE2EError
        .postSwitchSelectionInvalid("The post-switch selection points to a different saved-account origin.")
    }
    guard let capturedEquivalent = store.capturedEquivalents[selected.id] else {
      throw ClaudeSwitchLiveE2EError
        .postSwitchSelectionInvalid("The post-switch live Claude account lost its saved-copy mapping.")
    }
    guard capturedEquivalent.credentialSource == .quotariRegistry(id: targetID) else {
      throw ClaudeSwitchLiveE2EError
        .postSwitchSelectionInvalid("The post-switch live Claude account maps to a different saved target.")
    }
    guard store.errors[.claude] == nil else {
      throw ClaudeSwitchLiveE2EError.usageRequestFailed
    }
    guard store.snapshots[.claude] != nil else {
      throw ClaudeSwitchLiveE2EError.usageSnapshotMissing
    }
  }

  private func verifyTargetAuthentication(_ context: ClaudeSwitchLiveE2EContext) async throws {
    let liveProfile = try await resolvedLiveProfile(context)
    guard stronglyMatches(context.targetIdentity, profile: liveProfile) else {
      throw ClaudeSwitchLiveE2EError.targetProfileMismatch
    }
    guard try claudeAuthStatus(executable: context.claudeExecutable).matches(profile: liveProfile) else {
      throw ClaudeSwitchLiveE2EError.freshCLIAuthenticationFailed
    }
  }

  private func restoreAndCleanUp(
    _ context: ClaudeSwitchLiveE2EContext,
    original: ClaudeOriginalAccountState,
    store: UsageStore
  ) async throws {
    try await restoreOriginalAccountIfNeeded(context, original: original, store: store)
    try removeTestCreatedOriginalBackup(
      from: context.registry,
      preserving: context.idsBefore,
      original: original
    )
  }

  private func restoreOriginalAccountIfNeeded(
    _ context: ClaudeSwitchLiveE2EContext,
    original: ClaudeOriginalAccountState,
    store: UsageStore
  ) async throws {
    try requireClaudeIsNotRunning(context.detector)
    if await (liveAuthenticationEvidence(context)).matches(original: original.profile) {
      return
    }

    let registered = try context.registry.registeredAccounts(for: .claude)
    guard let originalCapture = registered.first(where: {
      $0.claudeAccountIdentity.map { stronglyMatches($0, profile: original.profile) } == true
        && ProviderCredentialIdentity.key(provider: .claude, payload: $0.payload) == original.identity
    }) else {
      throw ClaudeSwitchLiveE2EError.originalBackupUnavailable
    }
    await store.reloadAccounts()
    guard let originalAccount = store.accounts[.claude]?.first(where: {
      $0.credentialSource == .quotariRegistry(id: originalCapture.id)
    }) else {
      throw ClaudeSwitchLiveE2EError.originalBackupUnavailable
    }

    await store.switchCLIAccount(to: originalAccount)
    guard store.captureErrors[.claude] == nil else {
      throw ClaudeSwitchLiveE2EError.restorationSwitchFailed
    }
    await store.selectionRefreshTasks[.claude]?.value
    guard await (liveAuthenticationEvidence(context)).matches(original: original.profile) else {
      throw ClaudeSwitchLiveE2EError.restoredCLIIdentityMismatch
    }
  }

  private func liveAuthenticationEvidence(
    _ context: ClaudeSwitchLiveE2EContext
  ) async -> ClaudeLiveAuthenticationEvidence {
    let credentialProfile = try? await resolvedLiveProfile(context)
    let cliStatus = try? claudeAuthStatus(executable: context.claudeExecutable)
    return ClaudeLiveAuthenticationEvidence(
      credentialProfile: credentialProfile,
      cliStatus: cliStatus
    )
  }

  private func resolvedLiveProfile(
    _ context: ClaudeSwitchLiveE2EContext
  ) async throws -> ClaudeProfile {
    let live = try ClaudeCredentialsStore.loadResolved(environment: context.environment)
    var profile = try await ClaudeProfileFetcher().fetchProfile(
      accessToken: live.credentials.accessToken
    )
    profile.fingerprint = ProviderCredentialIdentity.fingerprint(of: live.credentials.accessToken)
    return profile
  }
}
