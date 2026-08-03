import Darwin
import Foundation
@testable import QuotariCore
import Testing

struct CLIActivitySnapshotTests {
  @Test func snapshotNormalizesProcessesAndApprovesOnlyItsProvider() {
    let snapshot = CLIActivitySnapshot(
      provider: .claude,
      processes: ["claude (PID 42)", "claude (PID 7)", "claude (PID 42)"]
    )

    #expect(snapshot.processes == ["claude (PID 42)", "claude (PID 7)"])
    #expect(snapshot.isActive)
    #expect(snapshot.unapprovedProcesses(
      for: .claude,
      activeProcesses: ["claude (PID 7)", "claude (PID 42)"]
    ).isEmpty)
    #expect(snapshot.unapprovedProcesses(
      for: .claude,
      activeProcesses: ["claude (PID 42)", "claude (PID 99)"]
    ) == ["claude (PID 99)"])
    #expect(snapshot.unapprovedProcesses(
      for: .codex,
      activeProcesses: ["codex (PID 42)"]
    ) == ["codex (PID 42)"])
  }

  @Test func reusedPIDWithANewerProcessGenerationIsNotApproved() {
    let displayName = "claude (PID 42)"
    let approved = CLIActivityProcess(
      displayName: displayName,
      generation: .process(startTimeSeconds: 100, startTimeMicroseconds: 1)
    )
    let reused = CLIActivityProcess(
      displayName: displayName,
      generation: .process(startTimeSeconds: 200, startTimeMicroseconds: 2)
    )
    let snapshot = CLIActivitySnapshot(provider: .claude, processes: [approved])

    #expect(snapshot.processes == [displayName])
    #expect(snapshot.unapprovedProcesses(for: .claude, activeProcesses: [reused]) == [displayName])
  }
}

struct AccountSwitchActiveSessionApprovalTests {
  @Test func userApprovedClaudeProcessCanRemainActiveDuringSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let live = approvalClaudeCredential(accessToken: "live", refreshToken: "live-ref")
    let keychain = KeychainSlot(live)
    let cli = try ApprovalCLIProcess()
    defer { cli.stop() }
    let approved = cli.activityProcess
    let stoppedDuringWrite = ApprovalFlag()
    let service = AccountSwitchService(
      capturedAccounts: registry,
      capture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in keychain.value }
      ),
      environment: [:],
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { data, _ in
        stoppedDuringWrite.value = cli.isStopped
        keychain.value = data
      },
      activeCLIProcessRecords: { _ in [approved] }
    )

    let source = try service.switchCLI(
      toRegistryAccount: saved.id,
      now: .distantPast,
      allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: [approved])
    )

    #expect(source == .claudeKeychain(service: ClaudeCredentialsStore.keychainService))
    #expect(try ClaudeCredentialsStore.parse(#require(keychain.value)).accessToken == "saved-tok")
    #expect(stoppedDuringWrite.value)
    #expect(!cli.isStopped)
  }

  @Test func unapprovedClaudeProcessAppearingAfterConfirmationStopsSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let original = approvalClaudeCredential(accessToken: "live", refreshToken: "live-ref")
    let keychain = KeychainSlot(original)
    let cli = try ApprovalCLIProcess()
    defer { cli.stop() }
    let approved = cli.activityProcess
    let unapproved = rotationProcess(pid: 99, generation: 2)
    let activity = ApprovalProcessActivitySequence([
      [approved],
      [approved],
      [approved, unapproved],
    ])
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
      activeCLIProcessRecords: { _ in activity.next() }
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(
        toRegistryAccount: saved.id,
        now: .distantPast,
        allowingActiveSessions: CLIActivitySnapshot(
          provider: .claude,
          processes: [approved]
        )
      )
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case let .cliStillRunning(processes) = thrown else {
      Issue.record("expected .cliStillRunning, got \(String(describing: thrown))")
      return
    }
    #expect(processes == [unapproved.displayName])
    #expect(keychain.value == original)
    #expect(!cli.isStopped)
  }

  @Test func activeClaudeProcessCannotOutliveTheSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let live = approvalClaudeCredential(accessToken: "live", refreshToken: "live-ref")
    let keychain = KeychainSlot(live)
    let active = ["claude (PID 42)"]
    let service = approvalSwitchService(
      registry: registry,
      home: home,
      keychain: keychain,
      activeProcesses: active
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case let .cliStillRunning(processes) = thrown else {
      Issue.record("expected .cliStillRunning, got \(String(describing: thrown))")
      return
    }
    #expect(processes == active)
    #expect(keychain.value == live)
  }

  @Test func allActiveProcessesAreReportedWhenSwitchingIsBlocked() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedClaudeAccount(registry: registry)
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let original = approvalClaudeCredential(accessToken: "live", refreshToken: "live-ref")
    let keychain = KeychainSlot(original)
    let service = approvalSwitchService(
      registry: registry,
      home: home,
      keychain: keychain,
      activeProcesses: ["claude (PID 42)", "claude (PID 99)"]
    )

    var thrown: AccountSwitchError?
    do {
      try service.switchCLI(toRegistryAccount: saved.id, now: .distantPast)
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case let .cliStillRunning(processes) = thrown else {
      Issue.record("expected .cliStillRunning, got \(String(describing: thrown))")
      return
    }
    #expect(processes == ["claude (PID 42)", "claude (PID 99)"])
    #expect(keychain.value == original)
  }
}

struct ClaudeLoginActiveSessionApprovalTests {
  @Test func userApprovedClaudeProcessCanRemainActiveDuringLoginPreparation() async throws {
    let fixture = try ApprovalLoginFixture(name: "approved", script: "#!/bin/sh\nexit 0\n")
    defer { fixture.remove() }
    let previous = approvalClaudeCredential(accessToken: "previous", refreshToken: "previous-ref")
    let added = approvalClaudeCredential(accessToken: "added", refreshToken: "added-ref")
    let credentials = ApprovalCredentialSequence([previous, previous, added])
    let active = ["claude (PID 42)"]

    let result = try await LiveClaudeAccountLogin.perform(
      environment: fixture.environment,
      home: fixture.directory,
      keychainRead: { _ in credentials.next() },
      activeCLIProcesses: { _ in active },
      credentialReadAttempts: 1,
      retryDelay: .zero,
      allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: active)
    )

    #expect(result.payload == added)
  }

  @Test func unapprovedClaudeProcessAppearingAfterConfirmationStopsLogin() async throws {
    let fixture = try ApprovalLoginFixture(
      name: "unapproved",
      script: "#!/bin/sh\ntouch \"$QUOTARI_TEST_MARKER\"\n",
      includesMarker: true
    )
    defer { fixture.remove() }
    let credential = approvalClaudeCredential(accessToken: "current", refreshToken: "current-ref")
    let activity = ApprovalActivitySequence([
      ["claude (PID 42)"],
      ["claude (PID 42)", "claude (PID 99)"],
    ])

    do {
      _ = try await LiveClaudeAccountLogin.perform(
        environment: fixture.environment,
        home: fixture.directory,
        keychainRead: { _ in credential },
        activeCLIProcesses: { _ in activity.next() },
        credentialReadAttempts: 1,
        retryDelay: .zero,
        allowingActiveSessions: CLIActivitySnapshot(
          provider: .claude,
          processes: ["claude (PID 42)"]
        )
      )
      Issue.record("A process launched after confirmation should stop login")
    } catch let error as AccountLoginError {
      guard case let .cliStillRunning(.claude, processes) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
      #expect(processes == ["claude (PID 99)"])
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
  }
}

private func approvalSwitchService(
  registry: CapturedAccountStore,
  home: URL,
  keychain: KeychainSlot,
  activeProcesses: [String]
) -> AccountSwitchService {
  AccountSwitchService(
    capturedAccounts: registry,
    capture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in keychain.value }
    ),
    environment: [:],
    home: home,
    keychainRead: { _ in keychain.value },
    keychainWrite: { data, _ in keychain.value = data },
    activeCLIProcesses: { _ in activeProcesses }
  )
}

private func approvalClaudeCredential(accessToken: String, refreshToken: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
  )
}

private struct ApprovalLoginFixture {
  let directory: URL
  let executable: URL
  let marker: URL
  let environment: [String: String]

  init(name: String, script: String, includesMarker: Bool = false) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    executable = directory.appendingPathComponent("fake-claude")
    marker = directory.appendingPathComponent("launched")
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var environment = ["QUOTARI_CLAUDE_PATH": executable.path, "PATH": "/usr/bin:/bin"]
    if includesMarker {
      environment["QUOTARI_TEST_MARKER"] = marker.path
    }
    self.environment = environment
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class ApprovalCredentialSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Data]

  init(_ values: [Data]) {
    self.values = values
  }

  func next() -> Data? {
    lock.withLock {
      guard values.count > 1 else { return values.first }
      return values.removeFirst()
    }
  }
}

private final class ApprovalActivitySequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[String]]

  init(_ values: [[String]]) {
    self.values = values
  }

  func next() -> [String] {
    lock.withLock {
      guard values.count > 1 else { return values.first ?? [] }
      return values.removeFirst()
    }
  }
}

private final class ApprovalProcessActivitySequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[CLIActivityProcess]]

  init(_ values: [[CLIActivityProcess]]) {
    self.values = values
  }

  func next() -> [CLIActivityProcess] {
    lock.withLock {
      guard values.count > 1 else { return values.first ?? [] }
      return values.removeFirst()
    }
  }
}

private final class ApprovalFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class ApprovalCLIProcess: @unchecked Sendable {
  private let process: Process

  init() throws {
    process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
  }

  var activityProcess: CLIActivityProcess {
    rotationProcess(pid: process.processIdentifier, generation: 1)
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
}
