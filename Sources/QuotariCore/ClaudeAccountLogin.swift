import Foundation

/// Claude Code keeps exactly one renewable OAuth login in the macOS Keychain,
/// so a browser login necessarily replaces the live CLI slot. The app layer
/// captures that slot before calling this service. This boundary then waits
/// for a genuinely different renewable credential and returns its raw bytes;
/// the registry import and rollback remain the app layer's responsibility.
enum LiveClaudeAccountLogin {
  static func perform(
    beforeCredentialOverwrite: (@Sendable (Data?) async throws -> Void)? = nil,
    duringLoginCredentialChange: (@Sendable (Data?) async throws -> Void)? = nil,
    onLoginStarted: CredentialMutationHandler? = nil,
    onCredentialObserved: CredentialObservationHandler? = nil,
    onOutput: AccountLoginOutputHandler? = nil,
    input: AccountLoginInput? = nil,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot? = nil
  ) async throws -> AccountLoginResult {
    let fileManager = FileManager.default
    return try await perform(
      environment: ProcessInfo.processInfo.environment,
      home: fileManager.homeDirectoryForCurrentUser,
      fileManager: fileManager,
      keychainRead: { try KeychainItemStore.readByService($0) },
      beforeCredentialOverwrite: beforeCredentialOverwrite,
      duringLoginCredentialChange: duringLoginCredentialChange,
      onLoginStarted: onLoginStarted,
      onCredentialObserved: onCredentialObserved,
      onOutput: onOutput,
      input: input,
      allowingActiveSessions: activitySnapshot
    )
  }

  static func perform(
    environment: [String: String],
    home: URL,
    fileManager: FileManager = .default,
    keychainRead: @escaping @Sendable (String) throws -> Data?,
    activeCLIProcesses: (@Sendable (UsageProvider) throws -> [String])? = nil,
    activeCLIProcessRecords: @escaping @Sendable (UsageProvider) throws -> [CLIActivityProcess] =
      CLIActivityDetector().activeProcessRecords,
    credentialReadAttempts: Int = 6,
    retryDelay: Duration = .milliseconds(250),
    loginTimeout: Duration = .seconds(600),
    credentialPreservationInterval: Duration = .milliseconds(100),
    beforeCredentialOverwrite: (@Sendable (Data?) async throws -> Void)? = nil,
    duringLoginCredentialChange: (@Sendable (Data?) async throws -> Void)? = nil,
    onLoginStarted: CredentialMutationHandler? = nil,
    onCredentialObserved: CredentialObservationHandler? = nil,
    onOutput: AccountLoginOutputHandler? = nil,
    input: AccountLoginInput? = nil,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot? = nil
  ) async throws -> AccountLoginResult {
    let runtime = try loginRuntime(
      environment: environment,
      home: home,
      fileManager: fileManager,
      keychainRead: keychainRead,
      observer: onCredentialObserved
    )
    let activeCLIProcessRecords = resolvedProcessRecords(
      legacy: activeCLIProcesses,
      records: activeCLIProcessRecords
    )
    let previousPayload = try await credentialAtOverwriteBoundary(
      keychainRead: keychainRead,
      activeCLIProcessRecords: activeCLIProcessRecords,
      beforeCredentialOverwrite: beforeCredentialOverwrite,
      allowingActiveSessions: activitySnapshot
    )
    let status = try await runLoginCommandPreservingCredentialChanges(
      command: ClaudeLoginCommandContext(
        configuration: runtime.configuration,
        executable: runtime.executable,
        timeout: loginTimeout,
        observers: AccountLoginCommandObservers(
          output: onOutput,
          didLaunch: onLoginStarted,
          input: input,
          completionOutput: "Login successful"
        ),
        observation: runtime.observation
      ),
      keychainRead: keychainRead,
      initialPayload: previousPayload,
      preservationInterval: credentialPreservationInterval,
      preserveCredential: activitySnapshot?.isActive == true ? duringLoginCredentialChange : nil
    )
    try Task.checkCancellation()
    try validateLoginStatus(status)
    let payload = try await changedCredential(
      after: renewableCredential(from: previousPayload),
      keychainRead: keychainRead,
      attempts: credentialReadAttempts,
      retryDelay: retryDelay
    )
    let finalObservation = runtime.observation.capture(matching: payload)
    runtime.observation.report(finalObservation)
    return accountLoginResult(
      configuration: runtime.configuration,
      payload: payload,
      observation: finalObservation
    )
  }

  private static func accountLoginResult(
    configuration: AccountLoginConfiguration,
    payload: Data,
    observation: ClaudeLoginCredentialObservation?
  ) -> AccountLoginResult {
    let oauthAccount = observation?.accountState.flatMap { configuration in
      try? ClaudeCodeAccountState.oauthAccount(from: configuration)
    }
    return AccountLoginResult(
      provider: .claude,
      origin: configuration.origin,
      payload: payload,
      claudeOAuthAccount: oauthAccount,
      claudeLoginObservation: observation
    )
  }

  static let keychainService = ClaudeCredentialsStore.keychainService

  private static func validateLoginStatus(_ status: Int32) throws {
    guard status == 0 else {
      throw AccountLoginError.commandFailed(.claude, status: status)
    }
  }

  private enum LoginCommandOutcome {
    case status(Int32)
    case timedOut
  }

  static func runLoginCommand(
    configuration: AccountLoginConfiguration,
    executable: URL,
    environment: [String: String],
    timeout: Duration,
    observers: AccountLoginCommandObservers
  ) async throws -> Int32 {
    let outcome = try await withThrowingTaskGroup(of: LoginCommandOutcome.self) { group in
      group.addTask {
        let status = try await IsolatedAccountLogin.runLoginCommand(
          executable: executable,
          arguments: configuration.arguments,
          environment: loginEnvironment(environment, executable: executable),
          currentDirectory: configuration.authDirectory,
          observers: observers
        )
        return .status(status)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        return .timedOut
      }
      let first = try await group.next() ?? .timedOut
      group.cancelAll()
      return first
    }
    switch outcome {
    case let .status(status): return status
    case .timedOut: throw AccountLoginError.loginTimedOut(.claude)
    }
  }

  static func configuration(home: URL) -> AccountLoginConfiguration {
    AccountLoginConfiguration(
      executableName: "claude",
      executableOverrideEnvironmentKey: "QUOTARI_CLAUDE_PATH",
      arguments: ["auth", "login"],
      authDirectory: home,
      credentialURL: home,
      isolatedEnvironment: [:],
      origin: .claudeKeychain(service: keychainService)
    )
  }

  private static func loginEnvironment(_ environment: [String: String], executable: URL) -> [String: String] {
    var result = environment
    let executableDirectory = executable.deletingLastPathComponent().path
    let existingPath = result["PATH"] ?? ""
    result["PATH"] = existingPath.isEmpty ? executableDirectory : "\(executableDirectory):\(existingPath)"
    result["NO_COLOR"] = "1"
    return result
  }

  private static func renewableCredential(from payload: Data?) -> Data? {
    payload.flatMap { ProviderCredentialMinimizer.minimize(provider: .claude, payload: $0) }
  }

  private static func changedCredential(
    after previousCredential: Data?,
    keychainRead: @escaping @Sendable (String) throws -> Data?,
    attempts requestedAttempts: Int,
    retryDelay: Duration
  ) async throws -> Data {
    let attempts = max(1, requestedAttempts)
    for attempt in 0 ..< attempts {
      try Task.checkCancellation()
      if let payload = try keychainRead(keychainService),
         let renewable = renewableCredential(from: payload),
         renewable != previousCredential {
        return payload
      }
      if attempt < attempts - 1 {
        try await Task.sleep(for: retryDelay)
      }
    }
    if previousCredential != nil {
      throw AccountLoginError.credentialUnchanged(.claude)
    }
    throw AccountLoginError.credentialUnavailable(.claude)
  }
}
