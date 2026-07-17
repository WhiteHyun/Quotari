import Foundation

/// Claude Code keeps exactly one renewable OAuth login in the macOS Keychain,
/// so a browser login necessarily replaces the live CLI slot. The app layer
/// captures that slot before calling this service. This boundary then waits
/// for a genuinely different renewable credential and returns its raw bytes;
/// the registry import and rollback remain the app layer's responsibility.
enum LiveClaudeAccountLogin {
  static func perform(
    beforeCredentialOverwrite: (@Sendable (Data?) async throws -> Void)? = nil,
    onLoginStarted: CredentialMutationHandler? = nil,
    onCredentialObserved: CredentialObservationHandler? = nil,
    onOutput: AccountLoginOutputHandler? = nil,
    input: AccountLoginInput? = nil
  ) async throws -> AccountLoginResult {
    let fileManager = FileManager.default
    return try await perform(
      environment: ProcessInfo.processInfo.environment,
      home: fileManager.homeDirectoryForCurrentUser,
      fileManager: fileManager,
      keychainRead: { try KeychainItemStore.readByService($0) },
      beforeCredentialOverwrite: beforeCredentialOverwrite,
      onLoginStarted: onLoginStarted,
      onCredentialObserved: onCredentialObserved,
      onOutput: onOutput,
      input: input
    )
  }

  static func perform(
    environment: [String: String],
    home: URL,
    fileManager: FileManager = .default,
    keychainRead: @escaping @Sendable (String) throws -> Data?,
    activeCLIProcesses: @escaping @Sendable (UsageProvider) throws -> [String] =
      CLIActivityDetector().activeProcesses,
    credentialReadAttempts: Int = 6,
    retryDelay: Duration = .milliseconds(250),
    loginTimeout: Duration = .seconds(600),
    beforeCredentialOverwrite: (@Sendable (Data?) async throws -> Void)? = nil,
    onLoginStarted: CredentialMutationHandler? = nil,
    onCredentialObserved: CredentialObservationHandler? = nil,
    onOutput: AccountLoginOutputHandler? = nil,
    input: AccountLoginInput? = nil
  ) async throws -> AccountLoginResult {
    let configuration = configuration(home: home)
    guard let executable = IsolatedAccountLogin.executableURL(
      for: configuration,
      environment: environment,
      home: home,
      fileManager: fileManager
    ) else {
      throw AccountLoginError.executableNotFound(.claude)
    }
    let observation = ClaudeLoginObservationContext(
      environment: environment,
      home: home,
      fileManager: fileManager,
      keychainRead: keychainRead,
      observer: onCredentialObserved
    )
    let previousPayload = try await credentialAtOverwriteBoundary(
      keychainRead: keychainRead,
      activeCLIProcesses: activeCLIProcesses,
      beforeCredentialOverwrite: beforeCredentialOverwrite
    )
    let previousCredential = renewableCredential(from: previousPayload)
    let status = try await runLoginCommandReportingCredential(
      configuration: configuration,
      executable: executable,
      timeout: loginTimeout,
      observers: AccountLoginCommandObservers(
        output: onOutput,
        didLaunch: onLoginStarted,
        input: input,
        completionOutput: "Login successful"
      ),
      observation: observation
    )
    try Task.checkCancellation()
    try validateLoginStatus(status)
    let payload = try await changedCredential(
      after: previousCredential,
      keychainRead: keychainRead,
      attempts: credentialReadAttempts,
      retryDelay: retryDelay
    )
    let finalObservation = observation.capture(matching: payload)
    observation.report(finalObservation)
    return accountLoginResult(
      configuration: configuration,
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

  private static let keychainService = ClaudeCredentialsStore.keychainService

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

  private static func requireClaudeCLIInactive(
    _ activeCLIProcesses: @Sendable (UsageProvider) throws -> [String]
  ) throws {
    let active: [String]
    do {
      active = try activeCLIProcesses(.claude)
    } catch {
      throw AccountLoginError.cliActivityCheckFailed(.claude, underlying: error.localizedDescription)
    }
    guard active.isEmpty else {
      throw AccountLoginError.cliStillRunning(.claude, processes: active)
    }
  }

  private static func credentialAtOverwriteBoundary(
    keychainRead: @escaping @Sendable (String) throws -> Data?,
    activeCLIProcesses: @escaping @Sendable (UsageProvider) throws -> [String],
    beforeCredentialOverwrite: (@Sendable (Data?) async throws -> Void)?
  ) async throws -> Data? {
    try requireClaudeCLIInactive(activeCLIProcesses)
    var observed = try readClaudeKeychain(keychainRead)
    for _ in 0 ..< 3 {
      try await beforeCredentialOverwrite?(observed)
      try Task.checkCancellation()
      try requireClaudeCLIInactive(activeCLIProcesses)
      let current = try readClaudeKeychain(keychainRead)
      if current == observed {
        return current
      }
      observed = current
    }
    throw AccountLoginError.credentialChangedDuringPreparation(.claude)
  }

  private static func readClaudeKeychain(
    _ keychainRead: @Sendable (String) throws -> Data?
  ) throws -> Data? {
    do {
      return try keychainRead(keychainService)
    } catch {
      throw AccountLoginError.credentialReadFailed(.claude, underlying: error.localizedDescription)
    }
  }

  private static func configuration(home: URL) -> AccountLoginConfiguration {
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
