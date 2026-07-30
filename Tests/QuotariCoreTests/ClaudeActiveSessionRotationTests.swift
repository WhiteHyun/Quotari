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
    let active = ["claude (PID 42)"]

    let login = Task {
      try await LiveClaudeAccountLogin.perform(
        environment: fixture.environment,
        home: fixture.directory,
        keychainRead: { _ in keychain.value },
        activeCLIProcesses: { _ in active },
        credentialReadAttempts: 1,
        retryDelay: .zero,
        loginTimeout: .seconds(2),
        credentialPreservationInterval: .milliseconds(5),
        beforeCredentialOverwrite: { preserved.append($0) },
        duringLoginCredentialChange: { preserved.append($0) },
        allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: active)
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
}

private struct RotationLoginFixture {
  let directory: URL
  let started: URL
  let release: URL
  let environment: [String: String]

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-rotation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    started = directory.appendingPathComponent("started")
    release = directory.appendingPathComponent("release")
    let executable = directory.appendingPathComponent("fake-claude")
    let script = """
    #!/bin/sh
    touch "$QUOTARI_TEST_STARTED"
    while [ ! -f "$QUOTARI_TEST_RELEASE" ]; do /bin/sleep 0.01; done
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    environment = [
      "PATH": "/usr/bin:/bin",
      "QUOTARI_CLAUDE_PATH": executable.path,
      "QUOTARI_TEST_RELEASE": release.path,
      "QUOTARI_TEST_STARTED": started.path,
    ]
  }

  func remove() {
    try? Data().write(to: release)
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class RotationCredentialBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Data

  init(_ value: Data) {
    storage = value
  }

  var value: Data {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class RotationCredentialRecorder: @unchecked Sendable {
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

private func waitForRotationCondition(_ condition: @escaping @Sendable () -> Bool) async throws {
  for _ in 0 ..< 200 {
    if condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw RotationTestTimeout()
}

private struct RotationTestTimeout: Error {}

private func rotationCredential(accessToken: String, refreshToken: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
  )
}
