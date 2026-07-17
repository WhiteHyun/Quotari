import Darwin
import Foundation

struct AccountLoginCommandObservers: Sendable {
  var output: AccountLoginOutputHandler?
  var didLaunch: CredentialMutationHandler?
  var input: AccountLoginInput?

  init(
    output: AccountLoginOutputHandler? = nil,
    didLaunch: CredentialMutationHandler? = nil,
    input: AccountLoginInput? = nil
  ) {
    self.output = output
    self.didLaunch = didLaunch
    self.input = input
  }
}

final class AccountLoginProcessBox: @unchecked Sendable {
  private static let forceKillDelay = DispatchTimeInterval.seconds(1)

  private let lock = NSLock()
  private let process: Process
  private var cancelled = false
  private var forceKillScheduled = false

  init(_ process: Process) {
    self.process = process
  }

  func run() throws {
    try lock.withLock {
      if cancelled {
        throw CancellationError()
      }
      try process.run()
    }
  }

  func cancel() {
    let cancellation = lock.withLock {
      cancelled = true
      guard process.isRunning else { return (shouldTerminate: false, shouldScheduleForceKill: false) }
      let shouldScheduleForceKill = !forceKillScheduled
      forceKillScheduled = true
      return (shouldTerminate: true, shouldScheduleForceKill: shouldScheduleForceKill)
    }
    if cancellation.shouldTerminate {
      process.terminate()
    }
    if cancellation.shouldScheduleForceKill {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.forceKillDelay) { [self] in
        forceKillIfNeeded()
      }
    }
  }

  func waitUntilExit() -> Int32 {
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func forceKillIfNeeded() {
    lock.withLock {
      guard process.isRunning else { return }
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }
}
