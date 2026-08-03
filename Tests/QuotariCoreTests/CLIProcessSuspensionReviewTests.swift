import CustomDump
import Darwin
import Foundation
@testable import QuotariCore
import Testing

extension AccountSwitchActiveSessionApprovalTests {
  @Test func reusedApprovedPIDIsNeverSignaled() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let original = Data(#"{"claudeAiOauth":{"accessToken":"live","refreshToken":"live-ref"}}"#.utf8)
    let keychain = KeychainSlot(original)
    let cli = try ApprovalCLIProcess()
    defer { cli.stop() }
    let approved = cli.activityProcess
    guard case let .process(seconds, microseconds) = approved.generation else {
      Issue.record("Expected a kernel process generation")
      return
    }
    let reused = CLIActivityProcess(
      pid: approved.pid,
      displayName: approved.displayName,
      generation: .process(
        startTimeSeconds: seconds &+ 1,
        startTimeMicroseconds: microseconds
      )
    )
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in keychain.value }
      ),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in keychain.value = data },
      activeCLIProcessRecords: { _ in [reused] }
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(
        toRegistryAccount: saved.id,
        now: .distantPast,
        allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: [reused])
      )
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .concurrentCredentialChange = thrown else {
      Issue.record("expected .concurrentCredentialChange, got \(String(describing: thrown))")
      return
    }
    #expect(keychain.value == original)
    #expect(!cli.isStopped)
  }

  @Test func resumeFailuresDoNotSkipOtherSuspendedProcesses() {
    let processes = [1, 2, 3].map {
      CLIActivityProcess(
        pid: Int32($0),
        displayName: "claude (PID \($0))",
        generation: .process(startTimeSeconds: UInt64($0), startTimeMicroseconds: 0)
      )
    }
    var attempted: [Int32] = []
    var failureDescription: String?

    do {
      try AccountSwitchService.resumeCLIProcesses(processes) { process in
        let pid = try #require(process.pid)
        attempted.append(pid)
        guard pid == 2 else {
          throw NSError(
            domain: "CLIProcessResumeTest",
            code: Int(pid),
            userInfo: [NSLocalizedDescriptionKey: "resume failure \(pid)"]
          )
        }
      }
      Issue.record("Expected aggregated resume failures")
    } catch {
      failureDescription = error.localizedDescription
    }

    expectNoDifference(attempted, [3, 2, 1])
    expectNoDifference(
      failureDescription,
      "Resuming 2 Claude session(s) failed: "
        + "PID 3: resume failure 3; PID 1: resume failure 1"
    )
  }
}

final class ApprovalCLIProcess: @unchecked Sendable {
  private let process: Process
  let activityProcess: CLIActivityProcess

  init() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    self.process = process
    do {
      activityProcess = try Self.activityProcess(pid: process.processIdentifier)
    } catch {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      throw error
    }
  }

  var isStopped: Bool {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let readSize = proc_pidinfo(
      process.processIdentifier,
      PROC_PIDTBSDINFO,
      0,
      &info,
      expectedSize
    )
    return readSize == expectedSize && info.pbi_status == SSTOP
  }

  func stop() {
    _ = Darwin.kill(process.processIdentifier, SIGCONT)
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
  }

  private static func activityProcess(pid: Int32) throws -> CLIActivityProcess {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    errno = 0
    let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
    guard readSize == expectedSize else {
      throw NSError(
        domain: "ApprovalCLIProcess",
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "Could not inspect test process \(pid)."]
      )
    }
    return CLIActivityProcess(
      pid: pid,
      displayName: "claude (PID \(pid))",
      generation: .process(
        startTimeSeconds: info.pbi_start_tvsec,
        startTimeMicroseconds: info.pbi_start_tvusec
      )
    )
  }
}
