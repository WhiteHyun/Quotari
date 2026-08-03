import Foundation

extension AccountSwitchService {
  struct SuspendedCLIProcessOperationResult<Value> {
    var value: Value
    var warning: AccountSwitchWarning?
  }

  func withSuspendedApprovedCLIProcesses<Result>(
    _ snapshot: CLIActivitySnapshot,
    provider: UsageProvider,
    operation: () throws -> Result
  ) throws -> SuspendedCLIProcessOperationResult<Result> {
    let approved = try approvedProcesses(in: snapshot, provider: provider)
    // The watchdog is a separate Quotari invocation. It sends SIGSTOP itself,
    // remembers only signals it owns, and waits on a pipe held by this process.
    // EOF therefore resumes those sessions even if this process terminates.
    let resumeLease = try processResumeLease(approved)
    try resumeLease.suspend()

    try verifySuspendedProcesses(
      stillMatch: snapshot,
      provider: provider,
      resumeLease: resumeLease
    )

    let operationResult: Swift.Result<Result, Error>
    do {
      operationResult = try .success(operation())
    } catch {
      operationResult = .failure(error)
    }

    let resumeFailure: Error?
    do {
      try resumeLease.resume()
      resumeFailure = nil
    } catch {
      resumeFailure = error
    }

    return try finishSuspendedOperation(operationResult, resumeFailure: resumeFailure)
  }

  private func approvedProcesses(
    in snapshot: CLIActivitySnapshot,
    provider: UsageProvider
  ) throws -> [CLIActivityProcess] {
    let active = try checkedActiveCLIProcesses(provider)
    let blocked = snapshot.unapprovedProcesses(for: provider, activeProcesses: active)
    guard blocked.isEmpty else {
      throw AccountSwitchError.cliStillRunning(processes: blocked)
    }
    let approved = snapshot.approvedProcesses(for: provider, activeProcesses: active)
    guard approved.allSatisfy({ $0.pid != nil }) else {
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "An approved CLI process could not be safely paused."
      )
    }
    return approved
  }

  private func verifySuspendedProcesses(
    stillMatch snapshot: CLIActivitySnapshot,
    provider: UsageProvider,
    resumeLease: CLIProcessResumeLease
  ) throws {
    do {
      let current = try checkedActiveCLIProcesses(provider)
      let changed = snapshot.unapprovedProcesses(for: provider, activeProcesses: current)
      guard changed.isEmpty else { throw AccountSwitchError.concurrentCredentialChange }
    } catch {
      let suspensionError = error
      do {
        try resumeLease.resume()
      } catch {
        throw AccountSwitchError.cliSessionResumeFailed(
          underlying: "The switch was stopped before writing credentials, and "
            + error.localizedDescription
        )
      }
      throw suspensionError
    }
  }

  private func finishSuspendedOperation<Result>(
    _ operationResult: Swift.Result<Result, Error>,
    resumeFailure: Error?
  ) throws -> SuspendedCLIProcessOperationResult<Result> {
    switch operationResult {
    case let .success(value):
      return SuspendedCLIProcessOperationResult(
        value: value,
        warning: resumeFailure.map {
          AccountSwitchWarning.cliSessionResumeFailed(underlying: $0.localizedDescription)
        }
      )
    case let .failure(operationError):
      if let resumeFailure {
        throw AccountSwitchError.cliSessionResumeFailed(
          underlying: "The switch also failed (\(operationError.localizedDescription)), and "
            + resumeFailure.localizedDescription
        )
      }
      throw operationError
    }
  }
}
