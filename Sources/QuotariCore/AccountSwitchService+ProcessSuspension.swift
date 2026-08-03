import Darwin
import Foundation

extension AccountSwitchService {
  private enum CLIProcessState {
    case running
    case stopped
    case exited
    case replaced
  }

  private enum CLIProcessSignalResult {
    case sent
    case exited
    case replaced
  }

  func withSuspendedApprovedCLIProcesses<Result>(
    _ snapshot: CLIActivitySnapshot,
    provider: UsageProvider,
    operation: () throws -> Result
  ) throws -> Result {
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

    let signaledForSuspension = try suspendApprovedCLIProcesses(approved)
    do {
      let current = try checkedActiveCLIProcesses(provider)
      let changed = snapshot.unapprovedProcesses(for: provider, activeProcesses: current)
      guard changed.isEmpty else { throw AccountSwitchError.concurrentCredentialChange }
    } catch {
      let suspensionError = error
      do {
        try Self.resumeCLIProcesses(signaledForSuspension)
      } catch {
        throw AccountSwitchError.partialSwitch(
          underlying: "Claude session suspension failed and a paused session could not be resumed: "
            + error.localizedDescription
        )
      }
      throw suspensionError
    }

    let result: Swift.Result<Result, Error>
    do {
      result = try .success(operation())
    } catch {
      result = .failure(error)
    }
    do {
      try Self.resumeCLIProcesses(signaledForSuspension)
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: "The account switch finished, but a paused Claude session could not be resumed: "
          + error.localizedDescription
      )
    }
    return try result.get()
  }

  private func suspendApprovedCLIProcesses(
    _ processes: [CLIActivityProcess]
  ) throws -> [CLIActivityProcess] {
    var signaled: [CLIActivityProcess] = []
    do {
      for process in processes {
        switch try Self.processState(process) {
        case .running:
          break
        case .stopped, .exited:
          continue
        case .replaced:
          throw AccountSwitchError.concurrentCredentialChange
        }
        switch try Self.sendSignal(SIGSTOP, to: process) {
        case .sent:
          // SIGSTOP may still take effect after polling fails. Record our
          // ownership before waiting so every signaled process receives a
          // matching SIGCONT during error cleanup.
          signaled.append(process)
          _ = try Self.waitUntilStopped(process)
        case .exited:
          continue
        case .replaced:
          throw AccountSwitchError.concurrentCredentialChange
        }
      }
      return signaled
    } catch {
      let suspensionError = error
      do {
        try Self.resumeCLIProcesses(signaled)
      } catch {
        throw AccountSwitchError.partialSwitch(
          underlying: "Claude session suspension failed and a paused session could not be resumed: "
            + error.localizedDescription
        )
      }
      throw suspensionError
    }
  }

  private static func waitUntilStopped(_ process: CLIActivityProcess) throws -> Bool {
    for _ in 0 ..< 200 {
      switch try processState(process) {
      case .stopped:
        return true
      case .exited:
        return false
      case .replaced:
        throw AccountSwitchError.concurrentCredentialChange
      case .running:
        usleep(1000)
      }
    }
    throw AccountSwitchError.cliActivityCheckFailed(
      underlying: "Claude process \(process.pid ?? 0) did not pause before the account switch."
    )
  }

  private static func resumeCLIProcesses(_ processes: [CLIActivityProcess]) throws {
    for process in processes.reversed() {
      // SIGCONT is harmless if our process has not stopped yet, and it clears
      // a late-arriving SIGSTOP after polling failed. The signal helper checks
      // the process generation again and skips a reused PID.
      _ = try sendSignal(SIGCONT, to: process)
    }
  }

  private static func sendSignal(
    _ signal: Int32,
    to process: CLIActivityProcess
  ) throws -> CLIProcessSignalResult {
    guard let pid = process.pid else {
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "An approved CLI process had no stable process identifier."
      )
    }
    switch try processState(process) {
    case .running, .stopped:
      break
    case .exited:
      return .exited
    case .replaced:
      return .replaced
    }
    errno = 0
    guard Darwin.kill(pid, signal) == 0 else {
      if errno == ESRCH {
        return .exited
      }
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "Signaling CLI process \(pid) failed (errno \(errno))."
      )
    }
    return .sent
  }

  private static func processState(_ process: CLIActivityProcess) throws -> CLIProcessState {
    guard let pid = process.pid else { return .exited }
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    errno = 0
    let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
    guard readSize == expectedSize else {
      if readSize == 0, errno == ESRCH || errno == EINVAL {
        return .exited
      }
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "Inspecting CLI process \(pid) suspension failed (errno \(errno))."
      )
    }
    let generation = CLIActivityProcess.Generation.process(
      startTimeSeconds: info.pbi_start_tvsec,
      startTimeMicroseconds: info.pbi_start_tvusec
    )
    guard generation == process.generation else { return .replaced }
    return info.pbi_status == SSTOP ? .stopped : .running
  }
}
