import Darwin
import Foundation

public struct CLIProcessResumeLease: @unchecked Sendable {
  private let suspendOperation: @Sendable () throws -> Void
  private let resumeOperation: @Sendable () throws -> Void

  public init(
    suspend: @escaping @Sendable () throws -> Void,
    resume: @escaping @Sendable () throws -> Void
  ) {
    suspendOperation = suspend
    resumeOperation = resume
  }

  func suspend() throws {
    try suspendOperation()
  }

  func resume() throws {
    try resumeOperation()
  }
}

/// Runs outside Quotari's UI process and owns every SIGSTOP it sends. The
/// parent keeps the watchdog's stdin open while credentials are changing. A
/// normal completion closes that pipe deliberately; a crash or force-quit
/// closes it in the kernel. Either path makes the watchdog resume exactly the
/// process generations it paused before exiting.
public enum CLIProcessResumeWatchdog {
  public static let argument = "--quotari-cli-resume-watchdog"

  static let readyMarker = UInt8(ascii: "R")
  static let suspendMarker = UInt8(ascii: "S")
  static let errorMarker = UInt8(ascii: "E")

  private enum ProcessState {
    case running
    case stopped
    case exited
    case replaced
  }

  private enum SignalResult {
    case sent
    case exited
    case replaced
  }

  private struct ResumeError: LocalizedError {
    let failures: [String]

    var errorDescription: String? {
      "Resuming \(failures.count) Claude session(s) failed: "
        + failures.joined(separator: "; ")
    }
  }

  static func inProcessLease(
    for processes: [CLIActivityProcess]
  ) -> CLIProcessResumeLease {
    final class State: @unchecked Sendable {
      let lock = NSLock()
      var suspended: [CLIActivityProcess] = []
    }
    let state = State()
    return CLIProcessResumeLease(
      suspend: {
        let suspended = try suspendProcesses(processes)
        state.lock.withLock { state.suspended = suspended }
      },
      resume: {
        let suspended = state.lock.withLock { state.suspended }
        try resumeProcesses(suspended)
      }
    )
  }

  /// Returns an exit status only when the watchdog flag is present, allowing
  /// the app entry point to route the helper invocation before AppKit starts.
  public static func runIfRequested(
    arguments: [String] = CommandLine.arguments,
    input: FileHandle = .standardInput,
    output: FileHandle = .standardOutput
  ) -> Int32? {
    guard let argumentIndex = arguments.firstIndex(of: argument) else { return nil }
    let encodedProcesses = arguments.suffix(from: arguments.index(after: argumentIndex))
    let processes: [CLIActivityProcess]
    do {
      processes = try encodedProcesses.map(decode)
    } catch {
      writeError(error.localizedDescription, to: output)
      return EX_USAGE
    }

    do {
      try output.write(contentsOf: Data([readyMarker]))
      let command = try input.read(upToCount: 1) ?? Data()
      guard command.first == suspendMarker else { return EXIT_SUCCESS }
      let suspended = try suspendProcesses(processes)
      try output.write(contentsOf: Data([suspendMarker]))
      _ = try input.read(upToCount: 1)
      do {
        try resumeProcesses(suspended)
        try output.write(contentsOf: Data([readyMarker]))
        return EXIT_SUCCESS
      } catch {
        writeError(error.localizedDescription, to: output)
        return EX_SOFTWARE
      }
    } catch {
      writeError(error.localizedDescription, to: output)
      return EX_SOFTWARE
    }
  }

  static func resumeProcesses(
    _ processes: [CLIActivityProcess],
    using resume: (CLIActivityProcess) throws -> Void = { process in
      _ = try sendSignal(SIGCONT, to: process)
    }
  ) throws {
    var failures: [String] = []
    for process in processes.reversed() {
      do {
        try resume(process)
      } catch {
        failures.append("PID \(process.pid ?? 0): \(error.localizedDescription)")
      }
    }
    guard failures.isEmpty else { throw ResumeError(failures: failures) }
  }

  private static func suspendProcesses(
    _ processes: [CLIActivityProcess]
  ) throws -> [CLIActivityProcess] {
    var signaled: [CLIActivityProcess] = []
    do {
      for process in processes {
        switch try processState(process) {
        case .running:
          break
        case .stopped, .exited:
          continue
        case .replaced:
          throw AccountSwitchError.concurrentCredentialChange
        }
        switch try sendSignal(SIGSTOP, to: process) {
        case .sent:
          signaled.append(process)
          _ = try waitUntilStopped(process)
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
        try resumeProcesses(signaled)
      } catch {
        throw AccountSwitchError.cliSessionResumeFailed(
          underlying: "Session suspension failed and recovery also failed: "
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

  private static func sendSignal(
    _ signal: Int32,
    to process: CLIActivityProcess
  ) throws -> SignalResult {
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

  private static func processState(_ process: CLIActivityProcess) throws -> ProcessState {
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

  private static func decode(_ encoded: String) throws -> CLIActivityProcess {
    let components = encoded.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count == 3,
          let pid = Int32(components[0]),
          let seconds = UInt64(components[1]),
          let microseconds = UInt64(components[2])
    else {
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "The Claude session recovery watchdog received an invalid process identity."
      )
    }
    return CLIActivityProcess(
      pid: pid,
      displayName: "claude (PID \(pid))",
      generation: .process(
        startTimeSeconds: seconds,
        startTimeMicroseconds: microseconds
      )
    )
  }

  private static func writeError(_ message: String, to output: FileHandle) {
    try? output.write(contentsOf: Data([errorMarker]) + Data(message.utf8))
  }
}
