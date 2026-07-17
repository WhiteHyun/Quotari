import Foundation

extension IsolatedAccountLogin {
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
    let inputPipe = observers.input.map { _ in Pipe() }
    process.standardInput = inputPipe ?? FileHandle.nullDevice
    defer { observers.input?.finish() }
    if let inputPipe {
      try observers.input?.connect(inputPipe.fileHandleForWriting)
    }
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
