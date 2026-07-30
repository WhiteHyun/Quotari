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
  let credentialSamplingInterval: Duration
  let activityInspectionInterval: Duration
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
    case command(Data)
    case preservationStopped
  }

  static func runLoginCommandProtectingLoginWindow(
    command: ClaudeLoginCommandContext,
    protection: ClaudeLoginWindowProtection,
    afterCommand: @escaping @Sendable (Int32) async throws -> Data
  ) async throws -> Data {
    let tracker = ClaudeCredentialGenerationTracker(initialPayload: protection.initialPayload)
    let preservation = ClaudeCredentialPreservationContext(
      keychainRead: protection.keychainRead,
      activeCLIProcessRecords: protection.activeCLIProcessRecords,
      activitySnapshot: protection.activitySnapshot,
      credentialSamplingInterval: protection.credentialSamplingInterval,
      activityInspectionInterval: protection.activityInspectionInterval,
      preserveCredential: protection.preserveCredential,
      tracker: tracker,
      loginProcess: ClaudeLoginProcessTracker()
    )
    let commandResult: Result<Data, Error>
    do {
      let payload = try await runLoginCommandWhilePreservingCredentials(
        command: command,
        preservation: preservation,
        afterCommand: afterCommand
      )
      commandResult = .success(payload)
    } catch {
      commandResult = .failure(error)
    }
    // An activity failure stops new sampling, but generations already
    // observed before that failure are still durable user credentials. Drain
    // those generations before surfacing the original protection error.
    if let protectionError = tracker.error {
      try await preservePendingCredentialGenerations(preservation)
      throw protectionError
    }
    let sampledCredential = try sampleCurrentCredentialGeneration(preservation)
    if !sampledCredential {
      try inspectLoginWindowActivity(preservation)
    }
    try await preservePendingCredentialGenerations(preservation)
    return try commandResult.get()
  }

  private static func runLoginCommandWhilePreservingCredentials(
    command: ClaudeLoginCommandContext,
    preservation: ClaudeCredentialPreservationContext,
    afterCommand: @escaping @Sendable (Int32) async throws -> Data
  ) async throws -> Data {
    try await withThrowingTaskGroup(of: LoginWindowOutcome.self) { group in
      group.addTask {
        try await runLoginCommandAndObserveCredential(
          command: command,
          preservation: preservation,
          afterCommand: afterCommand
        )
      }
      group.addTask {
        await monitorLoginWindowActivity(preservation)
        return .preservationStopped
      }
      if preservation.preserveCredential != nil {
        group.addTask {
          await sampleCredentialGenerations(preservation)
          return .preservationStopped
        }
        group.addTask {
          await preserveCredentialGenerations(preservation)
          return .preservationStopped
        }
      }
      let first = try await group.next() ?? .preservationStopped
      group.cancelAll()
      switch first {
      case let .command(payload):
        return payload
      case .preservationStopped:
        throw CancellationError()
      }
    }
  }

  private static func runLoginCommandAndObserveCredential(
    command: ClaudeLoginCommandContext,
    preservation: ClaudeCredentialPreservationContext,
    afterCommand: @escaping @Sendable (Int32) async throws -> Data
  ) async throws -> LoginWindowOutcome {
    var observers = command.observers
    observers.processDidLaunch = { pid in
      preservation.loginProcess.recordLaunch(pid: pid)
      do {
        try inspectLoginWindowActivity(preservation)
      } catch {
        preservation.tracker.record(error: error)
      }
    }
    let status: Int32
    do {
      status = try await runLoginCommandReportingCredential(
        configuration: command.configuration,
        executable: command.executable,
        timeout: command.timeout,
        observers: observers,
        observation: command.observation
      )
    } catch {
      preservation.loginProcess.recordCompletion()
      throw error
    }
    preservation.loginProcess.recordCompletion()
    let payload = try await afterCommand(status)
    return .command(payload)
  }

  private static func monitorLoginWindowActivity(_ preservation: ClaudeCredentialPreservationContext) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: preservation.activityInspectionInterval)
        try Task.checkCancellation()
        try inspectLoginWindowActivity(preservation)
      } catch is CancellationError {
        return
      } catch {
        preservation.tracker.record(error: error)
        return
      }
    }
  }

  private static func sampleCredentialGenerations(_ preservation: ClaudeCredentialPreservationContext) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: preservation.credentialSamplingInterval)
        try Task.checkCancellation()
        _ = try sampleCurrentCredentialGeneration(preservation)
      } catch is CancellationError {
        return
      } catch {
        preservation.tracker.record(error: error)
        return
      }
    }
  }

  private static func preserveCredentialGenerations(_ preservation: ClaudeCredentialPreservationContext) async {
    while !Task.isCancelled {
      do {
        if preservation.tracker.pendingGeneration == nil {
          try await Task.sleep(for: preservation.credentialSamplingInterval)
        } else {
          try await preserveNextCredentialGeneration(preservation)
        }
      } catch is CancellationError {
        return
      } catch {
        preservation.tracker.record(error: error)
        return
      }
    }
  }

  private static func sampleCurrentCredentialGeneration(
    _ preservation: ClaudeCredentialPreservationContext
  ) throws -> Bool {
    if let error = preservation.tracker.error {
      throw error
    }
    guard preservation.preserveCredential != nil else { return false }
    let current = try readClaudeKeychain(preservation.keychainRead)
    guard preservation.tracker.isNew(sampledPayload: current) else { return false }
    try inspectLoginWindowActivity(preservation)
    return preservation.tracker.record(sampledPayload: current)
  }

  private static func preservePendingCredentialGenerations(
    _ preservation: ClaudeCredentialPreservationContext
  ) async throws {
    while preservation.tracker.pendingGeneration != nil {
      try await preserveNextCredentialGeneration(preservation)
    }
  }

  private static func preserveNextCredentialGeneration(
    _ preservation: ClaudeCredentialPreservationContext
  ) async throws {
    guard let preserveCredential = preservation.preserveCredential,
          let generation = preservation.tracker.pendingGeneration
    else { return }
    // A user cancellation must stop the browser command, but it cannot cancel
    // saving a credential generation that was already observed. Detached work
    // does not inherit the cancelled login task's status; awaiting it still
    // keeps restoration ordered behind this durable save.
    let preservationTask = Task.detached {
      try await preserveCredential(generation.payload)
    }
    try await preservationTask.value
    preservation.tracker.record(preserved: generation)
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
  let credentialSamplingInterval: Duration
  let activityInspectionInterval: Duration
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

private struct ClaudeCredentialGeneration: Equatable, Sendable {
  let payload: Data?
}

private final class ClaudeCredentialGenerationTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var sampledPayload: Data?
  private var pendingGenerations: [ClaudeCredentialGeneration] = []
  private var errorStorage: Error?

  init(initialPayload: Data?) {
    sampledPayload = initialPayload
  }

  var pendingGeneration: ClaudeCredentialGeneration? {
    lock.withLock { pendingGenerations.first }
  }

  var error: Error? {
    lock.withLock { errorStorage }
  }

  func record(sampledPayload: Data?) -> Bool {
    lock.withLock {
      guard sampledPayload != self.sampledPayload else { return false }
      self.sampledPayload = sampledPayload
      pendingGenerations.append(ClaudeCredentialGeneration(payload: sampledPayload))
      return true
    }
  }

  func isNew(sampledPayload: Data?) -> Bool {
    lock.withLock { sampledPayload != self.sampledPayload }
  }

  func record(preserved generation: ClaudeCredentialGeneration) {
    lock.withLock {
      guard pendingGenerations.first == generation else { return }
      pendingGenerations.removeFirst()
    }
  }

  func record(error: Error) {
    lock.withLock {
      if errorStorage == nil {
        errorStorage = error
      }
    }
  }
}
