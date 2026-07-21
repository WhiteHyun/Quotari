import Darwin
import Foundation
import Testing

struct ClaudeAccountSwitchRunnerSafetyTests {
  @Test
  func signalsAndForcedTerminationPreserveLockSafety() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appending(path: "QuotariRunnerSafety-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try writeExecutable("#!/bin/zsh\nexit 0\n", named: "claude", in: temporaryDirectory)
    try writeExecutable("#!/bin/zsh\nexit 1\n", named: "pgrep", in: temporaryDirectory)
    try writeExecutable(
      "#!/bin/zsh\nprint \"started:$$\" > \"$QUOTARI_SIGNAL_TEST_LOG\"\n"
        + "sleep 0.3\nprint restored >> \"$QUOTARI_SIGNAL_TEST_LOG\"\n",
      named: "swift",
      in: temporaryDirectory
    )
    try Data("stale lock file".utf8).write(to: runnerLockURL)

    for signal in [SIGHUP, SIGINT, SIGTERM] {
      try exerciseRunner(signal: signal, executableDirectory: temporaryDirectory)
    }
    try exerciseForcedTermination(executableDirectory: temporaryDirectory)
  }

  private func exerciseRunner(signal: Int32, executableDirectory: URL) throws {
    let logURL = executableDirectory.appending(path: "signal-\(signal).log")
    let (process, output) = makeRunner(logURL: logURL, executableDirectory: executableDirectory)

    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let childPID = try #require(waitForChildPID(in: logURL))
    let runnerGroup = try #require(validProcessGroup(for: process.processIdentifier))
    let childGroup = try #require(validProcessGroup(for: childPID))
    #expect(childGroup != runnerGroup)
    #expect(try lockProbeStatus() == 75)
    try #require(kill(process.processIdentifier, signal) == 0)
    process.waitUntilExit()

    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let outputText = try #require(String(bytes: outputData, encoding: .utf8))
    let logText = try String(contentsOf: logURL, encoding: .utf8)
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 130)
    #expect(outputText.contains("waiting for Claude credential restoration"))
    #expect(logText.split(whereSeparator: \.isNewline).last == "restored")
    #expect(try lockProbeStatus() == 0)
  }

  private func exerciseForcedTermination(executableDirectory: URL) throws {
    let logURL = executableDirectory.appending(path: "forced-termination.log")
    let (process, _) = makeRunner(logURL: logURL, executableDirectory: executableDirectory)
    try process.run()
    let childPID = try #require(waitForChildPID(in: logURL))
    defer {
      if kill(childPID, 0) == 0 {
        kill(childPID, SIGKILL)
      }
    }

    #expect(try lockProbeStatus() == 75)
    try #require(kill(process.processIdentifier, SIGKILL) == 0)
    process.waitUntilExit()
    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)
    #expect(try lockProbeStatus() == 75)
    try #require(waitForCleanup(in: logURL))
    let lockReleased = try waitForLockRelease()
    try #require(lockReleased)
  }

  private func makeRunner(logURL: URL, executableDirectory: URL) -> (Process, Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [
      runnerURL.path,
      "--target-id", "fake-registry-id",
      "--confirm-live-switch",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "CI")
    environment["PATH"] = "\(executableDirectory.path):\(environment["PATH"] ?? "")"
    environment["QUOTARI_SIGNAL_TEST_LOG"] = logURL.path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    return (process, output)
  }

  private func waitForChildPID(in logURL: URL) -> pid_t? {
    for _ in 0 ..< 200 {
      if let text = try? String(contentsOf: logURL, encoding: .utf8),
         let firstLine = text.split(whereSeparator: \.isNewline).first,
         let value = firstLine.split(separator: ":").last.flatMap({ pid_t($0) }) {
        return value
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return nil
  }

  private func waitForCleanup(in logURL: URL) -> Bool {
    for _ in 0 ..< 200 {
      if let text = try? String(contentsOf: logURL, encoding: .utf8),
         text.split(whereSeparator: \.isNewline).last == "restored" {
        return true
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return false
  }

  private func waitForLockRelease() throws -> Bool {
    for _ in 0 ..< 200 {
      if try lockProbeStatus() == 0 {
        return true
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return false
  }

  private func lockProbeStatus() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    process.arguments = ["-s", "-t", "0", "-k", runnerLockURL.path, "/usr/bin/true"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func validProcessGroup(for processID: pid_t) -> pid_t? {
    let group = getpgid(processID)
    return group == -1 ? nil : group
  }

  private func writeExecutable(_ contents: String, named name: String, in directory: URL) throws {
    let url = directory.appending(path: name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private var runnerURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Scripts/run-claude-switch-e2e.sh")
  }

  private var runnerLockURL: URL {
    FileManager.default.temporaryDirectory
      .appending(path: "com.whitehyun.Quotari.ClaudeSwitchE2E.\(geteuid()).lock")
  }
}
