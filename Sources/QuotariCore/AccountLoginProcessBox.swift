import Darwin
import Foundation

struct AccountLoginCommandObservers: Sendable {
  var output: AccountLoginOutputHandler?
  var didLaunch: CredentialMutationHandler?
  var processDidLaunch: (@Sendable (Int32) -> Void)?
  var input: AccountLoginInput?
  var completionOutput: String?

  init(
    output: AccountLoginOutputHandler? = nil,
    didLaunch: CredentialMutationHandler? = nil,
    processDidLaunch: (@Sendable (Int32) -> Void)? = nil,
    input: AccountLoginInput? = nil,
    completionOutput: String? = nil
  ) {
    self.output = output
    self.didLaunch = didLaunch
    self.processDidLaunch = processDidLaunch
    self.input = input
    self.completionOutput = completionOutput
  }
}

final class AccountLoginProcessBox: @unchecked Sendable {
  private static let successfulOutputGraceDelay = DispatchTimeInterval.milliseconds(500)
  private static let forceKillDelay = DispatchTimeInterval.seconds(1)

  private let lock = NSLock()
  private let process: Process
  private var cancelled = false
  private var forceKillScheduled = false

  init(_ process: Process) {
    self.process = process
  }

  func run(onTermination: @escaping @Sendable (Int32) -> Void) throws {
    try lock.withLock {
      if cancelled {
        throw CancellationError()
      }
      process.terminationHandler = { process in
        onTermination(process.terminationStatus)
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

  /// Give a CLI that already reported success a short window to flush its
  /// credential and account-state writes after stdin closes. If its stale
  /// authentication-code prompt still prevents exit, terminate it without
  /// making the UI wait for the full login timeout.
  func finishAfterSuccessfulOutput() {
    let shouldSchedule = lock.withLock {
      guard process.isRunning, !forceKillScheduled else { return false }
      forceKillScheduled = true
      return true
    }
    guard shouldSchedule else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + Self.successfulOutputGraceDelay
    ) { [self] in
      terminateAfterSuccessfulOutputIfNeeded()
    }
  }

  private func forceKillIfNeeded() {
    lock.withLock {
      guard process.isRunning else { return }
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }

  private func terminateAfterSuccessfulOutputIfNeeded() {
    let shouldTerminate = lock.withLock { process.isRunning }
    guard shouldTerminate else { return }
    process.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.forceKillDelay) { [self] in
      forceKillIfNeeded()
    }
  }
}
