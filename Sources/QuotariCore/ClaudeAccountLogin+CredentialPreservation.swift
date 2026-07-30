import Foundation

struct ClaudeLoginCommandContext: Sendable {
  let configuration: AccountLoginConfiguration
  let executable: URL
  let timeout: Duration
  let observers: AccountLoginCommandObservers
  let observation: ClaudeLoginObservationContext
}

struct ClaudeLoginWindowProtection: Sendable {
  let keychainRead: @Sendable (String) throws -> Data?
  let activeCLIProcessRecords: @Sendable (UsageProvider) throws -> [CLIActivityProcess]
  let initialPayload: Data?
  let interval: Duration
  let preserveCredential: (@Sendable (Data?) async throws -> Void)?
  let activitySnapshot: CLIActivitySnapshot?
}

extension ClaudeLoginRuntime {
  func loginCommand(
    timeout: Duration,
    output: AccountLoginOutputHandler?,
    didLaunch: CredentialMutationHandler?,
    input: AccountLoginInput?
  ) -> ClaudeLoginCommandContext {
    ClaudeLoginCommandContext(
      configuration: configuration,
      executable: executable,
      timeout: timeout,
      observers: AccountLoginCommandObservers(
        output: output,
        didLaunch: didLaunch,
        input: input,
        completionOutput: "Login successful"
      ),
      observation: observation
    )
  }
}

extension LiveClaudeAccountLogin {
  private enum LoginWindowOutcome {
    case command(Int32)
    case preservationStopped
  }

  static func runLoginCommandProtectingLoginWindow(
    command: ClaudeLoginCommandContext,
    protection: ClaudeLoginWindowProtection
  ) async throws -> Int32 {
    let tracker = ClaudeCredentialGenerationTracker(initialPayload: protection.initialPayload)
    let preservation = ClaudeCredentialPreservationContext(
      keychainRead: protection.keychainRead,
      activeCLIProcessRecords: protection.activeCLIProcessRecords,
      activitySnapshot: protection.activitySnapshot,
      interval: protection.interval,
      preserveCredential: protection.preserveCredential,
      tracker: tracker,
      loginProcess: ClaudeLoginProcessTracker()
    )
    let commandResult: Result<Int32, Error>
    do {
      let status = try await runLoginCommandWhilePreservingCredentials(
        command: command,
        preservation: preservation
      )
      commandResult = .success(status)
    } catch {
      commandResult = .failure(error)
    }
    try inspectLoginWindowActivity(preservation)
    try await preserveCurrentCredentialGeneration(preservation)
    return try commandResult.get()
  }

  private static func runLoginCommandWhilePreservingCredentials(
    command: ClaudeLoginCommandContext,
    preservation: ClaudeCredentialPreservationContext
  ) async throws -> Int32 {
    try await withThrowingTaskGroup(of: LoginWindowOutcome.self) { group in
      group.addTask {
        var observers = command.observers
        observers.processDidLaunch = { pid in
          preservation.loginProcess.recordLaunch(pid: pid)
          do {
            try inspectLoginWindowActivity(preservation)
          } catch {
            preservation.tracker.record(error: error)
          }
        }
        defer { preservation.loginProcess.recordCompletion() }
        let status = try await runLoginCommandReportingCredential(
          configuration: command.configuration,
          executable: command.executable,
          timeout: command.timeout,
          observers: observers,
          observation: command.observation
        )
        return .command(status)
      }
      group.addTask {
        await monitorCredentialGenerations(preservation)
        return .preservationStopped
      }
      let first = try await group.next() ?? .preservationStopped
      group.cancelAll()
      switch first {
      case let .command(status):
        return status
      case .preservationStopped:
        throw CancellationError()
      }
    }
  }

  private static func monitorCredentialGenerations(_ preservation: ClaudeCredentialPreservationContext) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: preservation.interval)
        try Task.checkCancellation()
        try inspectLoginWindowActivity(preservation)
        try await preserveCurrentCredentialGeneration(preservation)
      } catch is CancellationError {
        return
      } catch {
        preservation.tracker.record(error: error)
        return
      }
    }
  }

  private static func preserveCurrentCredentialGeneration(
    _ preservation: ClaudeCredentialPreservationContext
  ) async throws {
    if let error = preservation.tracker.error {
      throw error
    }
    guard let preserveCredential = preservation.preserveCredential else { return }
    let current = try readClaudeKeychain(preservation.keychainRead)
    guard current != preservation.tracker.payload else { return }
    try await preserveCredential(current)
    preservation.tracker.record(payload: current)
  }

  private static func inspectLoginWindowActivity(
    _ preservation: ClaudeCredentialPreservationContext
  ) throws {
    if let error = preservation.tracker.error {
      throw error
    }
    let active: [CLIActivityProcess]
    do {
      active = try preservation.activeCLIProcessRecords(.claude)
    } catch {
      throw AccountLoginError.cliActivityCheckFailed(.claude, underlying: error.localizedDescription)
    }
    let external = preservation.loginProcess.externalProcesses(from: active)
    let blocked = preservation.activitySnapshot?.unapprovedProcesses(
      for: .claude,
      activeProcesses: external
    ) ?? external.map(\.displayName)
    guard blocked.isEmpty else {
      throw AccountLoginError.cliStillRunning(.claude, processes: blocked)
    }
  }
}

private struct ClaudeCredentialPreservationContext: Sendable {
  let keychainRead: @Sendable (String) throws -> Data?
  let activeCLIProcessRecords: @Sendable (UsageProvider) throws -> [CLIActivityProcess]
  let activitySnapshot: CLIActivitySnapshot?
  let interval: Duration
  let preserveCredential: (@Sendable (Data?) async throws -> Void)?
  let tracker: ClaudeCredentialGenerationTracker
  let loginProcess: ClaudeLoginProcessTracker
}

private final class ClaudeLoginProcessTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var pid: Int32?
  private var process: CLIActivityProcess?
  private var hasCompleted = false

  func recordLaunch(pid: Int32) {
    lock.withLock { self.pid = pid }
  }

  func recordCompletion() {
    lock.withLock { hasCompleted = true }
  }

  func externalProcesses(from active: [CLIActivityProcess]) -> [CLIActivityProcess] {
    lock.withLock {
      if let process {
        return active.filter { $0 != process }
      }
      guard !hasCompleted,
            let pid,
            let launched = active.first(where: { $0.pid == pid })
      else { return active }
      process = launched
      return active.filter { $0 != launched }
    }
  }
}

private final class ClaudeCredentialGenerationTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var payloadStorage: Data?
  private var errorStorage: Error?

  init(initialPayload: Data?) {
    payloadStorage = initialPayload
  }

  var payload: Data? {
    lock.withLock { payloadStorage }
  }

  var error: Error? {
    lock.withLock { errorStorage }
  }

  func record(payload: Data?) {
    lock.withLock { payloadStorage = payload }
  }

  func record(error: Error) {
    lock.withLock { errorStorage = error }
  }
}
