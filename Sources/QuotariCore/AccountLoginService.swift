import Foundation

public struct AccountLoginResult: Sendable {
  public let provider: UsageProvider
  public let origin: ProviderCredentialSource
  public let payload: Data

  public init(
    provider: UsageProvider,
    origin: ProviderCredentialSource,
    payload: Data
  ) {
    self.provider = provider
    self.origin = origin
    self.payload = payload
  }
}

public typealias AccountLoginOutputHandler = @Sendable (String) async -> Void
public typealias CredentialPreservationHandler = @Sendable (
  UsageProvider, ProviderCredentialSource, Data?
) async throws -> Void
public typealias CredentialMutationHandler = @Sendable () -> Void
public enum AccountLoginError: LocalizedError, Sendable {
  case isolatedLoginUnavailable(UsageProvider)
  case executableNotFound(UsageProvider)
  case commandFailed(UsageProvider, status: Int32)
  case cliActivityCheckFailed(UsageProvider, underlying: String)
  case cliStillRunning(UsageProvider, processes: [String])
  case credentialReadFailed(UsageProvider, underlying: String)
  case credentialChangedDuringPreparation(UsageProvider)
  case loginTimedOut(UsageProvider)
  case credentialUnavailable(UsageProvider)
  case credentialUnchanged(UsageProvider)
  case temporaryCredentialCleanupFailed(UsageProvider)

  public var errorDescription: String? {
    switch self {
    case let .isolatedLoginUnavailable(provider):
      "Quotari can’t safely start \(provider.accountLoginCLIName) login with this configuration, so it won’t risk "
        + "replacing your current CLI account."
    case let .executableNotFound(provider):
      "Couldn’t find the \(provider.accountLoginCLIName) CLI. Install it or add it to PATH, then try again."
    case let .commandFailed(provider, status):
      "\(provider.accountLoginCLIName) login didn’t finish successfully (status \(status))."
    case let .cliActivityCheckFailed(provider, underlying):
      "Quotari couldn’t verify whether \(provider.accountLoginCLIName) is running, so it did not start login: "
        + underlying
    case let .cliStillRunning(provider, processes):
      "Close \(provider.accountLoginCLIName) before adding another account. Running: \(processes.joined(separator: ", "))."
    case let .credentialReadFailed(provider, underlying):
      "Quotari couldn’t read the current \(provider.accountLoginCLIName) credential, so it did not start login: "
        + underlying
    case let .credentialChangedDuringPreparation(provider):
      "The active \(provider.accountLoginCLIName) account kept changing while Quotari prepared login. Try again."
    case let .loginTimedOut(provider):
      "\(provider.accountLoginCLIName) login timed out. Start it again when you’re ready to finish in the browser."
    case let .credentialUnavailable(provider):
      "\(provider.accountLoginCLIName) login finished without a reusable account credential."
    case let .credentialUnchanged(provider):
      "\(provider.accountLoginCLIName) login finished, but the active account did not change. Choose a different "
        + "account in the browser and try again."
    case let .temporaryCredentialCleanupFailed(provider):
      "Quotari couldn’t securely remove the temporary \(provider.accountLoginCLIName) login credential."
    }
  }
}

/// Runs provider login in an isolated CLI home. A normal Codex login revokes
/// the credential already occupying its default slot, so Add Account must not
/// share the live configuration directory. Providers without an isolated
/// credential store fail closed. Only the successful temporary credential
/// bytes leave this service, and cleanup must succeed before they are returned.
public struct AccountLoginService: Sendable {
  private let operation: @Sendable (
    UsageProvider,
    AccountLoginOutputHandler?,
    CredentialPreservationHandler?,
    CredentialMutationHandler?
  ) async throws -> AccountLoginResult
  private let supportedProviders: Set<UsageProvider>

  public init() {
    supportedProviders = Set(UsageProvider.allCases)
    operation = { provider, onOutput, preserveCredential, credentialMutation in
      switch provider {
      case .claude:
        try await LiveClaudeAccountLogin.perform(
          beforeCredentialOverwrite: { payload in
            try await preserveCredential?(
              .claude,
              .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
              payload
            )
          },
          onLoginStarted: credentialMutation,
          onOutput: onOutput
        )
      case .codex:
        try await IsolatedAccountLogin.perform(provider: provider, onOutput: onOutput)
      }
    }
  }

  public init(
    operation: @escaping @Sendable (UsageProvider) async throws -> AccountLoginResult
  ) {
    supportedProviders = Set(UsageProvider.allCases)
    self.operation = { provider, _, _, _ in try await operation(provider) }
  }

  public init(
    streamingOperation: @escaping @Sendable (
      UsageProvider,
      AccountLoginOutputHandler?
    ) async throws -> AccountLoginResult
  ) {
    supportedProviders = Set(UsageProvider.allCases)
    operation = { provider, onOutput, _, _ in
      try await streamingOperation(provider, onOutput)
    }
  }

  public init(
    managedOperation: @escaping @Sendable (
      UsageProvider,
      AccountLoginOutputHandler?,
      CredentialPreservationHandler?,
      CredentialMutationHandler?
    ) async throws -> AccountLoginResult
  ) {
    supportedProviders = Set(UsageProvider.allCases)
    operation = managedOperation
  }

  public func supports(provider: UsageProvider) -> Bool {
    supportedProviders.contains(provider)
  }

  public func unavailableReason(provider: UsageProvider) -> String? {
    guard !supports(provider: provider) else { return nil }
    return AccountLoginError.isolatedLoginUnavailable(provider).localizedDescription
  }

  public func login(
    provider: UsageProvider,
    onOutput: AccountLoginOutputHandler? = nil,
    beforeCredentialOverwrite: CredentialPreservationHandler? = nil,
    onCredentialMutationPossible: CredentialMutationHandler? = nil
  ) async throws -> AccountLoginResult {
    guard supports(provider: provider) else {
      throw AccountLoginError.isolatedLoginUnavailable(provider)
    }
    return try await operation(
      provider,
      onOutput,
      beforeCredentialOverwrite,
      onCredentialMutationPossible
    )
  }
}

private extension UsageProvider {
  var accountLoginCLIName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }
}

struct AccountLoginConfiguration: Equatable {
  let executableName: String
  let executableOverrideEnvironmentKey: String
  let arguments: [String]
  let authDirectory: URL
  let credentialURL: URL
  let isolatedEnvironment: [String: String]
  let origin: ProviderCredentialSource
}

enum IsolatedAccountLogin {
  static func configuration(
    provider: UsageProvider,
    root: URL
  ) throws -> AccountLoginConfiguration {
    switch provider {
    case .claude:
      // Anthropic documents macOS OAuth storage as one encrypted Keychain
      // login; CLAUDE_CONFIG_DIR credential-file isolation is guaranteed only
      // on Linux and Windows. `claude setup-token` is non-destructive, but it
      // emits a one-year access token rather than the renewable credential pair
      // required by Quotari's managed registry. Keep this path fail-closed.
      throw AccountLoginError.isolatedLoginUnavailable(provider)
    case .codex:
      let directory = root.appendingPathComponent("codex", isDirectory: true)
      let credentialURL = directory.appendingPathComponent("auth.json")
      return AccountLoginConfiguration(
        executableName: "codex",
        executableOverrideEnvironmentKey: "QUOTARI_CODEX_PATH",
        // Quotari imports and then destroys this isolated auth.json. Force the
        // CLI's file backend so a user or future default cannot put the
        // temporary credential in the macOS Keychain instead.
        arguments: ["login", "--config", #"cli_auth_credentials_store="file""#],
        authDirectory: directory,
        credentialURL: credentialURL,
        isolatedEnvironment: ["CODEX_HOME": directory.path],
        origin: .codexAuthFile(path: credentialURL.path)
      )
    }
  }

  static func executableURL(
    for configuration: AccountLoginConfiguration,
    environment: [String: String],
    home: URL,
    fileManager: FileManager = .default
  ) -> URL? {
    var directories = environment["PATH"]?
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0), isDirectory: true) } ?? []
    directories += [
      home.appendingPathComponent(".local/bin", isDirectory: true),
      home.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
      home.appendingPathComponent(".mise/shims", isDirectory: true),
      home.appendingPathComponent(".asdf/shims", isDirectory: true),
      home.appendingPathComponent(".volta/bin", isDirectory: true),
      home.appendingPathComponent(".bun/bin", isDirectory: true),
      URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
      URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
      URL(fileURLWithPath: "/usr/bin", isDirectory: true),
    ]

    var candidates: [URL] = []
    if let override = environment[configuration.executableOverrideEnvironmentKey], !override.isEmpty {
      candidates.append(URL(fileURLWithPath: override))
    }
    candidates += directories.map { $0.appendingPathComponent(configuration.executableName) }
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
  }

  static func perform(
    provider: UsageProvider,
    onOutput: AccountLoginOutputHandler? = nil
  ) async throws -> AccountLoginResult {
    let fileManager = FileManager.default
    return try await perform(
      provider: provider,
      environment: ProcessInfo.processInfo.environment,
      home: fileManager.homeDirectoryForCurrentUser,
      temporaryDirectory: fileManager.temporaryDirectory,
      fileManager: fileManager,
      onOutput: onOutput
    )
  }

  static func perform(
    provider: UsageProvider,
    environment: [String: String],
    home: URL,
    temporaryDirectory: URL,
    fileManager: FileManager = .default,
    onOutput: AccountLoginOutputHandler? = nil
  ) async throws -> AccountLoginResult {
    let root = temporaryDirectory
      .appendingPathComponent("Quotari-AddAccount-\(UUID().uuidString)", isDirectory: true)
    let configuration = try configuration(provider: provider, root: root)
    guard let executable = executableURL(
      for: configuration,
      environment: environment,
      home: home,
      fileManager: fileManager
    ) else {
      throw AccountLoginError.executableNotFound(provider)
    }

    try fileManager.createDirectory(
      at: configuration.authDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let outcome: Result<AccountLoginResult, any Error>
    do {
      outcome = try await .success(executeLogin(
        provider: provider,
        configuration: configuration,
        executable: executable,
        environment: environment,
        onOutput: onOutput
      ))
    } catch {
      outcome = .failure(error)
    }

    do {
      try fileManager.removeItem(at: root)
    } catch {
      throw AccountLoginError.temporaryCredentialCleanupFailed(provider)
    }
    return try outcome.get()
  }

  private static func executeLogin(
    provider: UsageProvider,
    configuration: AccountLoginConfiguration,
    executable: URL,
    environment: [String: String],
    onOutput: AccountLoginOutputHandler?
  ) async throws -> AccountLoginResult {
    var loginEnvironment = environment
    configuration.isolatedEnvironment.forEach { loginEnvironment[$0.key] = $0.value }
    let executableDirectory = executable.deletingLastPathComponent().path
    let existingPath = loginEnvironment["PATH"] ?? ""
    loginEnvironment["PATH"] = existingPath.isEmpty
      ? executableDirectory
      : "\(executableDirectory):\(existingPath)"
    loginEnvironment["NO_COLOR"] = "1"

    let status = try await runLoginCommand(
      executable: executable,
      arguments: configuration.arguments,
      environment: loginEnvironment,
      currentDirectory: configuration.authDirectory.deletingLastPathComponent(),
      observers: AccountLoginCommandObservers(output: onOutput)
    )
    try Task.checkCancellation()
    guard status == 0 else {
      throw AccountLoginError.commandFailed(provider, status: status)
    }
    guard let payload = try? Data(contentsOf: configuration.credentialURL), !payload.isEmpty else {
      throw AccountLoginError.credentialUnavailable(provider)
    }
    return AccountLoginResult(
      provider: provider,
      origin: configuration.origin,
      payload: payload
    )
  }

  static func runLoginCommand(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectory: URL,
    observers: AccountLoginCommandObservers
  ) async throws -> Int32 {
    let process = Process()
    // Run the CLI itself so cancellation terminates the process that owns the
    // OAuth callback and credential write, rather than only a TTY wrapper.
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectory
    process.standardInput = FileHandle.nullDevice
    let outputPipe = observers.output.map { _ in Pipe() }
    process.standardOutput = outputPipe?.fileHandleForWriting ?? FileHandle.nullDevice
    process.standardError = outputPipe?.fileHandleForWriting ?? FileHandle.nullDevice
    let box = AccountLoginProcessBox(process)
    let outputReader = outputPipe.flatMap { pipe in
      observers.output.map { AccountLoginOutputReader(pipe: pipe, handler: $0) }
    }
    outputReader?.start()

    let status: Int32
    do {
      status = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          do {
            try box.run()
            // Establish the recovery marker synchronously after launch, then
            // observe process completion on a worker. Even an executable that
            // exits inside `Process.run()` cannot publish its status first.
            observers.didLaunch?()
            try? outputPipe?.fileHandleForWriting.close()
            Task.detached {
              continuation.resume(returning: box.waitUntilExit())
            }
          } catch {
            try? outputPipe?.fileHandleForWriting.close()
            continuation.resume(throwing: error)
          }
        }
      } onCancel: {
        box.cancel()
      }
    } catch {
      outputReader?.cancel()
      throw error
    }
    await outputReader?.finish()
    return status
  }
}
