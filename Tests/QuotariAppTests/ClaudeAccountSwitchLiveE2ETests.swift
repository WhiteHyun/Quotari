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
    let targetOAuthAccount = try requiredOAuthAccount(for: target)

    let originalCredentials = try ClaudeCredentialsStore.loadResolved(environment: environment)
    if case .claudeEnvironment = originalCredentials.source {
      throw ClaudeSwitchLiveE2EError.environmentCredentialUnsupported
    }
    try await runRoundTrip(ClaudeSwitchLiveE2EContext(
      registry: registry,
      idsBefore: idsBefore,
      target: target,
      targetOAuthAccount: targetOAuthAccount,
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
    let originalFingerprint = ProviderCredentialIdentity.fingerprint(
      of: context.originalCredentials.credentials.accessToken
    )
    var originalProfile = try await ClaudeProfileFetcher().fetchProfile(
      accessToken: context.originalCredentials.credentials.accessToken
    )
    originalProfile.fingerprint = originalFingerprint
    guard originalProfile.hasStableAccountIdentity else {
      throw ClaudeSwitchLiveE2EError.originalIdentityUnavailable
    }
    guard !ClaudeCodeAccountState.matches(context.targetOAuthAccount, profile: originalProfile) else {
      throw ClaudeSwitchLiveE2EError.targetIsCurrentAccount
    }

    let initialStatus = try claudeAuthStatus(executable: context.claudeExecutable)
    guard initialStatus.matches(profile: originalProfile) else {
      throw ClaudeSwitchLiveE2EError.initialCLIIdentityMismatch
    }
    let originalIdentity = ProviderCredentialIdentity.claudeIdentity(
      refreshToken: context.originalCredentials.credentials.refreshToken,
      accessToken: context.originalCredentials.credentials.accessToken
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
    let live = try ClaudeCredentialsStore.loadResolved(environment: context.environment)
    var liveProfile = try await ClaudeProfileFetcher().fetchProfile(
      accessToken: live.credentials.accessToken
    )
    liveProfile.fingerprint = ProviderCredentialIdentity.fingerprint(of: live.credentials.accessToken)
    guard ClaudeCodeAccountState.matches(context.targetOAuthAccount, profile: liveProfile) else {
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
    if try claudeAuthStatus(executable: context.claudeExecutable).matches(profile: original.profile) {
      return
    }

    let registered = try context.registry.registeredAccounts(for: .claude)
    guard let originalCapture = registered.first(where: {
      ProviderCredentialIdentity.key(provider: .claude, payload: $0.payload) == original.identity
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
    guard try claudeAuthStatus(executable: context.claudeExecutable).matches(profile: original.profile) else {
      throw ClaudeSwitchLiveE2EError.restoredCLIIdentityMismatch
    }
  }
}

private struct ClaudeSwitchLiveE2EContext {
  var registry: CapturedAccountStore
  var idsBefore: Set<String>
  var target: CapturedAccount
  var targetOAuthAccount: Data
  var originalCredentials: ResolvedClaudeCredentials
  var claudeExecutable: URL
  var detector: CLIActivityDetector
  var environment: [String: String]
}

private struct ClaudeOriginalAccountState {
  var identity: String
  var profile: ClaudeProfile
}

private struct ClaudeCLIAuthStatus: Decodable {
  var loggedIn: Bool
  var email: String?

  func matches(profile: ClaudeProfile) -> Bool {
    guard loggedIn, let expected = profile.email, let email else { return false }
    return email.localizedCaseInsensitiveCompare(expected) == .orderedSame
  }
}

private enum ClaudeSwitchLiveE2EError: LocalizedError {
  case missingEnvironment(String)
  case claudeExecutableUnavailable
  case quotariIsRunning
  case claudeIsRunning
  case environmentCredentialUnsupported
  case targetNotFound
  case targetIdentityUnavailable
  case targetIsCurrentAccount
  case targetNotSwitchable
  case originalIdentityUnavailable
  case initialCLIIdentityMismatch
  case switchFailed
  case postSwitchSelectionInvalid(String)
  case usageRequestFailed
  case usageSnapshotMissing
  case targetProfileMismatch
  case freshCLIAuthenticationFailed
  case originalBackupUnavailable
  case restorationSwitchFailed
  case restoredCLIIdentityMismatch
  case cliStatusFailed
  case restorationFailedAfterTestFailure(test: String, restoration: String)

  var errorDescription: String? {
    switch self {
    case let .missingEnvironment(name): "Set \(name) before running the live E2E test."
    case .claudeExecutableUnavailable: "The Claude Code executable could not be found."
    case .quotariIsRunning: "Quit the packaged Quotari app before running the live E2E test."
    case .claudeIsRunning: "Quit every Claude Code session before running the live E2E test."
    case .environmentCredentialUnsupported: "Unset QUOTARI_CLAUDE_OAUTH_TOKEN before the live E2E test."
    case .targetNotFound: "The requested saved Claude account was not found."
    case .targetIdentityUnavailable: "The target account has no verified Claude identity snapshot."
    case .targetIsCurrentAccount: "Choose a saved Claude account different from the current CLI login."
    case .targetNotSwitchable: "The target is not available as a saved, switchable account."
    case .originalIdentityUnavailable: "The current Claude login has no stable, renewable identity."
    case .initialCLIIdentityMismatch: "Claude Code auth status does not match the current OAuth credential."
    case .switchFailed: "Quotari did not complete the Claude account switch."
    case let .postSwitchSelectionInvalid(reason): reason
    case .usageRequestFailed: "The post-switch live Claude usage request returned an error."
    case .usageSnapshotMissing: "The post-switch live Claude usage request returned no snapshot."
    case .targetProfileMismatch: "The post-usage live OAuth profile does not match the selected target."
    case .freshCLIAuthenticationFailed: "A fresh Claude Code process was not authenticated as the target account."
    case .originalBackupUnavailable: "The original Claude login backup could not be found for restoration."
    case .restorationSwitchFailed: "Quotari could not switch the Claude CLI back to the original account."
    case .restoredCLIIdentityMismatch: "A fresh Claude Code process did not confirm the restored account."
    case .cliStatusFailed: "claude auth status --json failed or returned malformed output."
    case let .restorationFailedAfterTestFailure(test, restoration):
      "The live E2E failed (\(test)) and restoration also failed (\(restoration))."
    }
  }
}

private func requiredEnvironment(_ name: String, in environment: [String: String]) throws -> String {
  guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw ClaudeSwitchLiveE2EError.missingEnvironment(name)
  }
  return value
}

private func selectedTarget(id: String, from accounts: [CapturedAccount]) throws -> CapturedAccount {
  guard let target = accounts.first(where: { $0.id == id }) else {
    throw ClaudeSwitchLiveE2EError.targetNotFound
  }
  return target
}

private func requiredOAuthAccount(for account: CapturedAccount) throws -> Data {
  guard let oauthAccount = account.claudeOAuthAccount,
        let object = try? JSONSerialization.jsonObject(with: oauthAccount) as? [String: Any],
        object["emailAddress"] is String
  else { throw ClaudeSwitchLiveE2EError.targetIdentityUnavailable }
  return oauthAccount
}

private func claudeExecutableURL(environment: [String: String]) throws -> URL {
  if let explicit = environment["QUOTARI_E2E_CLAUDE_PATH"],
     FileManager.default.isExecutableFile(atPath: explicit) {
    return URL(fileURLWithPath: explicit)
  }
  for directory in environment["PATH", default: ""].split(separator: ":") {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("claude")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  throw ClaudeSwitchLiveE2EError.claudeExecutableUnavailable
}

private func claudeAuthStatus(executable: URL) throws -> ClaudeCLIAuthStatus {
  let process = Process()
  process.executableURL = executable
  process.arguments = ["auth", "status", "--json"]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = Pipe()
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0,
        let status = try? JSONDecoder().decode(ClaudeCLIAuthStatus.self, from: data)
  else { throw ClaudeSwitchLiveE2EError.cliStatusFailed }
  return status
}

private func requireClaudeIsNotRunning(_ detector: CLIActivityDetector) throws {
  guard try detector.activeProcesses(for: .claude).isEmpty else {
    throw ClaudeSwitchLiveE2EError.claudeIsRunning
  }
}

private func requireQuotariIsNotRunning() throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
  process.arguments = ["-x", "Quotari"]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
  if process.terminationStatus == 0 {
    throw ClaudeSwitchLiveE2EError.quotariIsRunning
  }
}

private func removeTestCreatedOriginalBackup(
  from registry: CapturedAccountStore,
  preserving ids: Set<String>,
  original: ClaudeOriginalAccountState
) throws {
  let candidates = try registry.registeredAccounts(for: .claude).filter { !ids.contains($0.id) }
  for candidate in candidates {
    let matchesAccountState = candidate.claudeOAuthAccount.map {
      ClaudeCodeAccountState.matches($0, profile: original.profile)
    } == true
    let matchesCredential = ProviderCredentialIdentity.key(
      provider: .claude,
      payload: candidate.payload
    ) == original.identity
    guard matchesAccountState || matchesCredential else { continue }
    try registry.remove(id: candidate.id)
  }
}
