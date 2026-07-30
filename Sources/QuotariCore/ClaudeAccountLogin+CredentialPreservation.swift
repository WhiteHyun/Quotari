import Foundation

struct ClaudeLoginCommandContext: Sendable {
  let configuration: AccountLoginConfiguration
  let executable: URL
  let timeout: Duration
  let observers: AccountLoginCommandObservers
  let observation: ClaudeLoginObservationContext
}

extension LiveClaudeAccountLogin {
  private enum LoginWindowOutcome {
    case command(Int32)
    case preservationStopped
  }

  static func runLoginCommandPreservingCredentialChanges(
    command: ClaudeLoginCommandContext,
    keychainRead: @escaping @Sendable (String) throws -> Data?,
    initialPayload: Data?,
    preservationInterval: Duration,
    preserveCredential: (@Sendable (Data?) async throws -> Void)?
  ) async throws -> Int32 {
    guard let preserveCredential else {
      return try await runLoginCommandReportingCredential(
        configuration: command.configuration,
        executable: command.executable,
        timeout: command.timeout,
        observers: command.observers,
        observation: command.observation
      )
    }
    let tracker = ClaudeCredentialGenerationTracker(initialPayload: initialPayload)
    let preservation = ClaudeCredentialPreservationContext(
      keychainRead: keychainRead,
      interval: preservationInterval,
      preserveCredential: preserveCredential,
      tracker: tracker
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
    try await preserveCurrentCredentialGeneration(preservation)
    return try commandResult.get()
  }

  private static func runLoginCommandWhilePreservingCredentials(
    command: ClaudeLoginCommandContext,
    preservation: ClaudeCredentialPreservationContext
  ) async throws -> Int32 {
    try await withThrowingTaskGroup(of: LoginWindowOutcome.self) { group in
      group.addTask {
        let status = try await runLoginCommandReportingCredential(
          configuration: command.configuration,
          executable: command.executable,
          timeout: command.timeout,
          observers: command.observers,
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
    let current = try readClaudeKeychain(preservation.keychainRead)
    guard current != preservation.tracker.payload else { return }
    try await preservation.preserveCredential(current)
    preservation.tracker.record(payload: current)
  }
}

private struct ClaudeCredentialPreservationContext: Sendable {
  let keychainRead: @Sendable (String) throws -> Data?
  let interval: Duration
  let preserveCredential: @Sendable (Data?) async throws -> Void
  let tracker: ClaudeCredentialGenerationTracker
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
