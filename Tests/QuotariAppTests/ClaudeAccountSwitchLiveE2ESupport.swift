import Foundation
@testable import Quotari
@testable import QuotariCore

struct ClaudeSwitchLiveE2EContext {
  var registry: CapturedAccountStore
  var idsBefore: Set<String>
  var target: CapturedAccount
  var targetOAuthAccount: Data
  var originalCredentials: ResolvedClaudeCredentials
  var claudeExecutable: URL
  var detector: CLIActivityDetector
  var environment: [String: String]
}

struct ClaudeOriginalAccountState {
  var identity: String
  var profile: ClaudeProfile
}

struct ClaudeCLIAuthStatus: Decodable {
  var loggedIn: Bool
  var email: String?

  func matches(profile: ClaudeProfile) -> Bool {
    guard loggedIn, let expected = profile.email, let email else { return false }
    return email.localizedCaseInsensitiveCompare(expected) == .orderedSame
  }
}

struct ClaudeLiveAuthenticationEvidence {
  var credentialProfile: ClaudeProfile?
  var cliStatus: ClaudeCLIAuthStatus?

  func matches(original: ClaudeProfile) -> Bool {
    guard let credentialProfile,
          sameClaudeAccount(credentialProfile, original),
          let cliStatus
    else { return false }
    return cliStatus.matches(profile: credentialProfile)
  }
}

enum ClaudeSwitchLiveE2EError: LocalizedError {
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
    case .restoredCLIIdentityMismatch: "The restored credential and fresh Claude Code identity did not agree."
    case .cliStatusFailed: "claude auth status --json failed or returned malformed output."
    case let .restorationFailedAfterTestFailure(test, restoration):
      "The live E2E failed (\(test)) and restoration also failed (\(restoration))."
    }
  }
}

func requiredEnvironment(_ name: String, in environment: [String: String]) throws -> String {
  guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw ClaudeSwitchLiveE2EError.missingEnvironment(name)
  }
  return value
}

func selectedTarget(id: String, from accounts: [CapturedAccount]) throws -> CapturedAccount {
  guard let target = accounts.first(where: { $0.id == id }) else {
    throw ClaudeSwitchLiveE2EError.targetNotFound
  }
  return target
}

func requiredOAuthAccount(for account: CapturedAccount) throws -> Data {
  guard let oauthAccount = account.claudeOAuthAccount,
        let object = try? JSONSerialization.jsonObject(with: oauthAccount) as? [String: Any],
        object["emailAddress"] is String
  else { throw ClaudeSwitchLiveE2EError.targetIdentityUnavailable }
  return oauthAccount
}

func claudeExecutableURL(environment: [String: String]) throws -> URL {
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

func claudeAuthStatus(executable: URL) throws -> ClaudeCLIAuthStatus {
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

func requireClaudeIsNotRunning(_ detector: CLIActivityDetector) throws {
  guard try detector.activeProcesses(for: .claude).isEmpty else {
    throw ClaudeSwitchLiveE2EError.claudeIsRunning
  }
}

func requireQuotariIsNotRunning() throws {
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

func removeTestCreatedOriginalBackup(
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

private func sameClaudeAccount(_ candidate: ClaudeProfile, _ original: ClaudeProfile) -> Bool {
  if let candidateID = nonempty(candidate.accountID),
     let originalID = nonempty(original.accountID) {
    return candidateID == originalID
  }
  guard let candidateEmail = nonempty(candidate.email),
        let originalEmail = nonempty(original.email)
  else { return false }
  return candidateEmail.localizedCaseInsensitiveCompare(originalEmail) == .orderedSame
}

private func nonempty(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  return value
}
