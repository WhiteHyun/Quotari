import Foundation
@testable import QuotariCore
import Testing

struct ClaudeActiveSessionRotationTests {
  @Test func preservesCredentialRotationsThroughoutAnApprovedBrowserLogin() async throws {
    let fixture = try RotationLoginFixture()
    defer { fixture.remove() }
    let original = rotationCredential(accessToken: "original", refreshToken: "original-refresh")
    let rotated = rotationCredential(accessToken: "rotated", refreshToken: "rotated-refresh")
    let added = rotationCredential(accessToken: "added", refreshToken: "added-refresh")
    let keychain = RotationCredentialBox(original)
    let preserved = RotationCredentialRecorder()
    let approved = rotationProcess(pid: 42, generation: 1)

    let login = Task {
      try await LiveClaudeAccountLogin.perform(
        environment: fixture.environment,
        home: fixture.directory,
        keychainRead: { _ in keychain.value },
        activeCLIProcessRecords: { _ in [approved] + fixture.loginProcessRecords },
        credentialReadAttempts: 1,
        retryDelay: .zero,
        loginTimeout: .seconds(2),
        credentialPreservationInterval: .milliseconds(5),
        activityInspectionInterval: .milliseconds(20),
        beforeCredentialOverwrite: { preserved.append($0) },
        duringLoginCredentialChange: { preserved.append($0) },
        allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: [approved])
      )
    }
    try await waitForRotationCondition {
      FileManager.default.fileExists(atPath: fixture.started.path)
    }

    keychain.value = rotated
    try await waitForRotationCondition { preserved.values.contains(rotated) }
    keychain.value = added
    try Data().write(to: fixture.release)

    let result = try await login.value

    #expect(result.payload == added)
    #expect(preserved.values.contains(original))
    #expect(preserved.values.contains(rotated))
    #expect(preserved.values.contains(added))
  }

  @Test func samplesLaterRotationsWhileAnEarlierGenerationIsBeingPreserved() async throws {
    let fixture = try RotationLoginFixture()
    defer { fixture.remove() }
    let original = rotationCredential(accessToken: "original", refreshToken: "original-refresh")
    let firstRotation = rotationCredential(accessToken: "first", refreshToken: "first-refresh")
    let laterRotation = rotationCredential(accessToken: "later", refreshToken: "later-refresh")
    let added = rotationCredential(accessToken: "added", refreshToken: "added-refresh")
    let keychain = RotationCredentialBox(original)
    let preserved = RotationCredentialRecorder()
    let gate = RotationPreservationGate(blocking: firstRotation)
    defer { gate.release() }
    let approved = rotationProcess(pid: 42, generation: 1)

    let login = Task {
      try await LiveClaudeAccountLogin.perform(
        environment: fixture.environment,
        home: fixture.directory,
        keychainRead: { _ in keychain.value },
        activeCLIProcessRecords: { _ in [approved] + fixture.loginProcessRecords },
        credentialReadAttempts: 1,
        retryDelay: .zero,
        loginTimeout: .seconds(2),
        credentialPreservationInterval: .milliseconds(5),
        activityInspectionInterval: .milliseconds(20),
        beforeCredentialOverwrite: { preserved.append($0) },
        duringLoginCredentialChange: {
          preserved.append($0)
          await gate.pauseIfNeeded($0)
        },
        allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: [approved])
      )
    }
    try await waitForRotationCondition { FileManager.default.fileExists(atPath: fixture.started.path) }

    keychain.value = firstRotation
    try await waitForRotationCondition { gate.isWaiting }
    keychain.value = laterRotation
    try await waitForRotationCondition { keychain.readValues.contains(laterRotation) }
    keychain.value = added
    try await waitForRotationCondition { keychain.readValues.contains(added) }
    gate.release()
    try await waitForRotationCondition { preserved.values.contains(laterRotation) }
    try Data().write(to: fixture.release)

    let result = try await login.value
    #expect(result.payload == added)
    #expect(preserved.values.contains(laterRotation))
  }

  @Test func credentialSamplingDoesNotRunAFullProcessScanAtTheSameCadence() async throws {
    let fixture = try RotationLoginFixture()
    defer { fixture.remove() }
    let original = rotationCredential(accessToken: "original", refreshToken: "original-refresh")
    let added = rotationCredential(accessToken: "added", refreshToken: "added-refresh")
    let keychain = RotationCredentialBox(original)
    let processInspections = RotationCounter()
    let approved = rotationProcess(pid: 42, generation: 1)

    let login = Task {
      try await LiveClaudeAccountLogin.perform(
        environment: fixture.environment,
        home: fixture.directory,
        keychainRead: { _ in keychain.value },
        activeCLIProcessRecords: { _ in
          processInspections.increment()
          return [approved] + fixture.loginProcessRecords
        },
        credentialReadAttempts: 1,
        retryDelay: .zero,
        loginTimeout: .seconds(2),
        credentialPreservationInterval: .milliseconds(5),
        activityInspectionInterval: .seconds(1),
        duringLoginCredentialChange: { _ in },
        allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: [approved])
      )
    }
    try await waitForRotationCondition { FileManager.default.fileExists(atPath: fixture.started.path) }
    try await waitForRotationCondition { keychain.readCount >= 8 }

    #expect(processInspections.value < keychain.readCount)
    keychain.value = added
    try await waitForRotationCondition { keychain.readValues.contains(added) }
    try Data().write(to: fixture.release)

    let result = try await login.value
    #expect(result.payload == added)
    #expect(processInspections.value <= 6)
  }

  @Test func processLaunchedDuringBrowserLoginStopsTheLogin() async throws {
    let fixture = try RotationLoginFixture()
    defer { fixture.remove() }
    let original = rotationCredential(accessToken: "original", refreshToken: "original-refresh")
    let keychain = RotationCredentialBox(original)
    let approved = rotationProcess(pid: 42, generation: 1)
    let unapproved = rotationProcess(pid: 99, generation: 2)
    let activity = RotationActivityBox([approved])

    let login = Task {
      try await LiveClaudeAccountLogin.perform(
        environment: fixture.environment,
        home: fixture.directory,
        keychainRead: { _ in keychain.value },
        activeCLIProcessRecords: { _ in activity.value + fixture.loginProcessRecords },
        credentialReadAttempts: 1,
        retryDelay: .zero,
        loginTimeout: .seconds(2),
        credentialPreservationInterval: .milliseconds(5),
        activityInspectionInterval: .milliseconds(5),
        duringLoginCredentialChange: { _ in },
        allowingActiveSessions: CLIActivitySnapshot(
          provider: .claude,
          processes: [approved]
        )
      )
    }
    try await waitForRotationCondition {
      FileManager.default.fileExists(atPath: fixture.started.path)
    }
    activity.value = [approved, unapproved]

    do {
      _ = try await login.value
      Issue.record("A process launched during browser login should stop login")
    } catch let error as AccountLoginError {
      guard case let .cliStillRunning(.claude, processes) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
      #expect(processes == ["claude (PID 99)"])
    }
  }
}

struct RotationLoginFixture {
  let directory: URL
  let started: URL
  let release: URL
  let finished: URL
  let processID: URL
  let environment: [String: String]

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-rotation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    started = directory.appendingPathComponent("started")
    release = directory.appendingPathComponent("release")
    finished = directory.appendingPathComponent("finished")
    processID = directory.appendingPathComponent("pid")
    let executable = directory.appendingPathComponent("fake-claude")
    let script = """
    #!/bin/sh
    echo "$$" > "$QUOTARI_TEST_PID"
    touch "$QUOTARI_TEST_STARTED"
    while [ ! -f "$QUOTARI_TEST_RELEASE" ]; do /bin/sleep 0.01; done
    touch "$QUOTARI_TEST_FINISHED"
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    environment = [
      "PATH": "/usr/bin:/bin",
      "QUOTARI_CLAUDE_PATH": executable.path,
      "QUOTARI_TEST_PID": processID.path,
      "QUOTARI_TEST_RELEASE": release.path,
      "QUOTARI_TEST_FINISHED": finished.path,
      "QUOTARI_TEST_STARTED": started.path,
    ]
  }

  func remove() {
    try? Data().write(to: release)
    try? FileManager.default.removeItem(at: directory)
  }

  var loginProcessRecords: [CLIActivityProcess] {
    guard let text = try? String(contentsOf: processID, encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return [] }
    return [rotationProcess(pid: pid, generation: 3)]
  }
}

final class RotationCredentialBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Data
  private var reads: [Data] = []

  init(_ value: Data) {
    storage = value
  }

  var value: Data {
    get {
      lock.withLock {
        reads.append(storage)
        return storage
      }
    }
    set { lock.withLock { storage = newValue } }
  }

  var readValues: [Data] {
    lock.withLock { reads }
  }

  var readCount: Int {
    lock.withLock { reads.count }
  }
}

final class RotationCredentialRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Data] = []

  var values: [Data] {
    lock.withLock { storage }
  }

  func append(_ value: Data?) {
    guard let value else { return }
    lock.withLock { storage.append(value) }
  }
}

final class RotationActivityBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CLIActivityProcess]

  init(_ value: [CLIActivityProcess]) {
    storage = value
  }

  var value: [CLIActivityProcess] {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

final class RotationPreservationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let blockedPayload: Data
  private var continuation: CheckedContinuation<Void, Never>?
  private var waiting = false
  private var released = false

  init(blocking payload: Data) {
    blockedPayload = payload
  }

  var isWaiting: Bool {
    lock.withLock { waiting }
  }

  func pauseIfNeeded(_ payload: Data?) async {
    guard payload == blockedPayload else { return }
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        waiting = true
        guard !released else { return true }
        self.continuation = continuation
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func release() {
    let continuation = lock.withLock {
      released = true
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume()
  }
}

final class RotationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func increment() {
    lock.withLock { storage += 1 }
  }
}

func waitForRotationCondition(_ condition: @escaping @Sendable () -> Bool) async throws {
  for _ in 0 ..< 600 {
    if condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw RotationTestTimeout()
}

private struct RotationTestTimeout: Error {}

func rotationCredential(accessToken: String, refreshToken: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
  )
}

func rotationProcess(pid: Int32, generation: UInt64) -> CLIActivityProcess {
  CLIActivityProcess(
    pid: pid,
    displayName: "claude (PID \(pid))",
    generation: .process(startTimeSeconds: generation, startTimeMicroseconds: 0)
  )
}
