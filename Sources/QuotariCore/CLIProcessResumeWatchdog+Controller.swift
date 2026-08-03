import Darwin
import Foundation

public extension CLIProcessResumeWatchdog {
  static func liveLease(
    for processes: [CLIActivityProcess]
  ) throws -> CLIProcessResumeLease {
    guard !processes.isEmpty else {
      return CLIProcessResumeLease(suspend: {}, resume: {})
    }
    let controller = try CLIProcessResumeWatchdogController(processes: processes)
    return CLIProcessResumeLease(
      suspend: { try controller.suspend() },
      resume: { try controller.resume() }
    )
  }
}

private final class CLIProcessResumeWatchdogController: @unchecked Sendable {
  private static let pollTimeoutMilliseconds: Int32 = 2000

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let lock = NSLock()
  private var didSuspend = false
  private var didFinish = false

  init(processes: [CLIActivityProcess]) throws {
    let executableURL = Bundle.main.executableURL
      ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
    guard let executableURL else {
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "Quotari could not locate its process-resume watchdog executable."
      )
    }

    let encodedProcesses = try processes.map(Self.encode)
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [CLIProcessResumeWatchdog.argument] + encodedProcesses
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    self.process = process
    input = inputPipe.fileHandleForWriting
    output = outputPipe.fileHandleForReading

    let inputFlags = fcntl(input.fileDescriptor, F_GETFD)
    if inputFlags >= 0 {
      _ = fcntl(input.fileDescriptor, F_SETFD, inputFlags | FD_CLOEXEC)
    }

    do {
      try process.run()
      try Self.expectMarker(
        CLIProcessResumeWatchdog.readyMarker,
        from: output,
        process: process,
        context: "starting"
      )
    } catch {
      try? input.close()
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "Starting the Claude session recovery watchdog failed: "
          + error.localizedDescription
      )
    }
  }

  deinit {
    try? input.close()
  }

  func suspend() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !didFinish, !didSuspend else { return }
    do {
      try input.write(contentsOf: Data([CLIProcessResumeWatchdog.suspendMarker]))
      try Self.expectMarker(
        CLIProcessResumeWatchdog.suspendMarker,
        from: output,
        process: process,
        context: "pausing Claude sessions"
      )
      didSuspend = true
    } catch {
      didFinish = true
      try? input.close()
      if process.isRunning {
        process.waitUntilExit()
      }
      throw error
    }
  }

  func resume() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !didFinish else { return }
    didFinish = true
    try? input.close()
    process.waitUntilExit()
    let response = (try? output.readToEnd()) ?? Data()
    guard process.terminationStatus == EXIT_SUCCESS,
          response.first == CLIProcessResumeWatchdog.readyMarker
    else {
      let message = Self.errorMessage(from: response)
      throw AccountSwitchError.cliSessionResumeFailed(
        underlying: message.isEmpty
          ? "The recovery watchdog exited without confirming every session resumed."
          : message
      )
    }
  }

  private static func encode(_ process: CLIActivityProcess) throws -> String {
    guard let pid = process.pid,
          case let .process(seconds, microseconds) = process.generation
    else {
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: "An approved CLI process had no stable kernel identity."
      )
    }
    return "\(pid):\(seconds):\(microseconds)"
  }

  private static func expectMarker(
    _ expected: UInt8,
    from output: FileHandle,
    process: Process,
    context: String
  ) throws {
    var descriptor = pollfd(
      fd: output.fileDescriptor,
      events: Int16(POLLIN | POLLHUP),
      revents: 0
    )
    errno = 0
    let pollResult = Darwin.poll(&descriptor, 1, pollTimeoutMilliseconds)
    guard pollResult > 0 else {
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: pollResult == 0
          ? "The Claude session recovery watchdog timed out while \(context)."
          : "Polling the Claude session recovery watchdog failed (errno \(errno))."
      )
    }
    let marker = try output.read(upToCount: 1) ?? Data()
    guard marker.first == expected else {
      if process.isRunning {
        process.waitUntilExit()
      }
      let remainder = (try? output.readToEnd()) ?? Data()
      let message = errorMessage(from: marker + remainder)
      throw AccountSwitchError.cliActivityCheckFailed(
        underlying: message.isEmpty
          ? "The Claude session recovery watchdog exited while \(context)."
          : message
      )
    }
  }

  private static func errorMessage(from data: Data) -> String {
    let payload = data.first == CLIProcessResumeWatchdog.errorMarker
      ? Data(data.dropFirst())
      : data
    return String(data: payload, encoding: .utf8) ?? ""
  }
}
