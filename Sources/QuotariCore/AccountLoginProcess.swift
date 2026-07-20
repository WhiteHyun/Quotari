import Foundation

extension IsolatedAccountLogin {
  static func runLoginCommand(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectory: URL,
    observers: AccountLoginCommandObservers
  ) async throws -> Int32 {
    let process = accountLoginProcess(
      executable: executable,
      arguments: arguments,
      environment: environment,
      currentDirectory: currentDirectory
    )
    defer { observers.input?.finish() }
    try configureAccountLoginInput(observers: observers, process: process)
    let box = AccountLoginProcessBox(process)
    let completionMatcher = observers.completionOutput.map(AccountLoginOutputMatcher.init)
    let outputHandler = accountLoginOutputHandler(
      observers: observers, completionMatcher: completionMatcher, process: box
    )
    let outputPipe = outputHandler.map { _ in Pipe() }
    process.standardOutput = outputPipe?.fileHandleForWriting ?? FileHandle.nullDevice
    process.standardError = outputPipe?.fileHandleForWriting ?? FileHandle.nullDevice
    let outputReader = outputPipe.flatMap { pipe in
      outputHandler.map { AccountLoginOutputReader(pipe: pipe, handler: $0) }
    }
    outputReader?.start()

    let status: Int32
    do {
      status = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          do {
            let completion = AccountLoginProcessCompletion { status in
              continuation.resume(returning: status)
            }
            try box.run { status in
              completion.processDidTerminate(with: status)
            }
            // Establish the recovery marker synchronously after launch, then
            // release a termination that may already have arrived. Even an
            // executable that exits inside `Process.run()` cannot publish its
            // status first.
            observers.didLaunch?()
            completion.didPublishLaunch()
            try? outputPipe?.fileHandleForWriting.close()
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
    return completionMatcher?.didMatch == true ? 0 : status
  }
}

private func configureAccountLoginInput(
  observers: AccountLoginCommandObservers,
  process: Process
) throws {
  let inputPipe = observers.input.map { _ in Pipe() }
  process.standardInput = inputPipe ?? FileHandle.nullDevice
  if let inputPipe {
    try observers.input?.connect(inputPipe.fileHandleForWriting)
  }
}

private final class AccountLoginProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let completion: @Sendable (Int32) -> Void
  private var hasPublishedLaunch = false
  private var terminationStatus: Int32?
  private var didComplete = false

  init(completion: @escaping @Sendable (Int32) -> Void) {
    self.completion = completion
  }

  func processDidTerminate(with status: Int32) {
    finishIfReady(after: { terminationStatus = status })
  }

  func didPublishLaunch() {
    finishIfReady(after: { hasPublishedLaunch = true })
  }

  private func finishIfReady(after update: () -> Void) {
    let status = lock.withLock { () -> Int32? in
      update()
      guard hasPublishedLaunch, let terminationStatus, !didComplete else { return nil }
      didComplete = true
      return terminationStatus
    }
    if let status {
      completion(status)
    }
  }
}

private func accountLoginProcess(
  executable: URL,
  arguments: [String],
  environment: [String: String],
  currentDirectory: URL
) -> Process {
  let process = Process()
  // Run the CLI itself so cancellation terminates the process that owns the
  // OAuth callback and credential write, rather than only a TTY wrapper.
  process.executableURL = executable
  process.arguments = arguments
  process.environment = environment
  process.currentDirectoryURL = currentDirectory
  return process
}

private func accountLoginOutputHandler(
  observers: AccountLoginCommandObservers,
  completionMatcher: AccountLoginOutputMatcher?,
  process: AccountLoginProcessBox
) -> AccountLoginOutputHandler? {
  guard observers.output != nil || completionMatcher != nil else { return nil }
  let forwardedOutput = observers.output
  let input = observers.input
  return { output in
    if completionMatcher?.append(output) == true {
      // Some Claude Code versions print a successful browser-login result
      // while their authentication-code prompt is still reading stdin. Close
      // that prompt and stop the command; the caller still verifies that a
      // genuinely new renewable credential was installed before accepting it.
      input?.finish()
      process.finishAfterSuccessfulOutput()
    }
    await forwardedOutput?(output)
  }
}

private final class AccountLoginOutputMatcher: @unchecked Sendable {
  private let lock = NSLock()
  private let pattern: String
  private var trailingOutput = ""
  private var matched = false

  var didMatch: Bool {
    lock.withLock { matched }
  }

  init(_ pattern: String) {
    self.pattern = pattern
  }

  func append(_ output: String) -> Bool {
    lock.withLock {
      guard !matched else { return false }
      let combined = trailingOutput + output
      if combined.localizedCaseInsensitiveContains(pattern) {
        matched = true
        trailingOutput = ""
        return true
      }
      trailingOutput = String(combined.suffix(max(0, pattern.count - 1)))
      return false
    }
  }
}
