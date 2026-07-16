import Foundation
@testable import QuotariCore
import Testing

struct ClaudeAccountLoginTests {
  @Test func loginLaunchesBrowserFlowAndReturnsChangedRenewableCredential() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("arguments")
    let executable = directory.appendingPathComponent("fake-claude")
    let script = """
    #!/bin/sh
    printf '%s' "$*" > "$QUOTARI_TEST_MARKER"
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let oldCredential = Data(
      #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-refresh"}}"#.utf8
    )
    let newCredential = Data(
      #"{"claudeAiOauth":{"accessToken":"new","refreshToken":"new-refresh"},"mcpOAuth":{"secret":"kept"}}"#.utf8
    )
    let credentials = CredentialSequence([oldCredential, oldCredential, newCredential])

    let result = try await LiveClaudeAccountLogin.perform(
      environment: [
        "QUOTARI_CLAUDE_PATH": executable.path,
        "QUOTARI_TEST_MARKER": marker.path,
        "PATH": "/usr/bin:/bin",
      ],
      home: directory,
      keychainRead: { _ in credentials.next() },
      activeCLIProcesses: { _ in [] },
      credentialReadAttempts: 1,
      retryDelay: .zero
    )

    #expect(try String(contentsOf: marker, encoding: .utf8) == "auth login")
    #expect(result.provider == .claude)
    #expect(result.origin == .claudeKeychain(service: ClaudeCredentialsStore.keychainService))
    #expect(result.payload == newCredential)
  }

  @Test func loginRejectsAnUnchangedCredential() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-unchanged-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-claude")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let credential = Data(
      #"{"claudeAiOauth":{"accessToken":"same","refreshToken":"same-refresh"}}"#.utf8
    )

    do {
      _ = try await LiveClaudeAccountLogin.perform(
        environment: ["QUOTARI_CLAUDE_PATH": executable.path, "PATH": "/usr/bin:/bin"],
        home: directory,
        keychainRead: { _ in credential },
        activeCLIProcesses: { _ in [] },
        credentialReadAttempts: 1,
        retryDelay: .zero
      )
      Issue.record("An unchanged credential should not be imported as a new account")
    } catch let error as AccountLoginError {
      guard case .credentialUnchanged(.claude) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
    }
  }

  @Test func loginPreservesAClaudeRotationObservedDuringPreparation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-rotation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-claude")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let original = claudeCredential(accessToken: "original", refreshToken: "original-refresh")
    let rotated = claudeCredential(accessToken: "rotated", refreshToken: "rotated-refresh")
    let added = claudeCredential(accessToken: "added", refreshToken: "added-refresh")
    let credentials = CredentialSequence([original, rotated, rotated, added])
    let preserved = ClaudePayloadRecorder()

    let result = try await LiveClaudeAccountLogin.perform(
      environment: ["QUOTARI_CLAUDE_PATH": executable.path, "PATH": "/usr/bin:/bin"],
      home: directory,
      keychainRead: { _ in credentials.next() },
      activeCLIProcesses: { _ in [] },
      credentialReadAttempts: 1,
      retryDelay: .zero,
      beforeCredentialOverwrite: { preserved.append($0) }
    )

    #expect(preserved.values == [original, rotated])
    #expect(result.payload == added)
  }

  @Test func loginRechecksClaudeActivityAfterCredentialPreservation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-activity-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched")
    let executable = directory.appendingPathComponent("fake-claude")
    try Data("#!/bin/sh\ntouch \"$QUOTARI_TEST_MARKER\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let credential = claudeCredential(accessToken: "current", refreshToken: "current-refresh")
    let activity = ClaudeActivitySequence([[], ["claude (PID 42)"]])

    do {
      _ = try await LiveClaudeAccountLogin.perform(
        environment: [
          "QUOTARI_CLAUDE_PATH": executable.path,
          "QUOTARI_TEST_MARKER": marker.path,
          "PATH": "/usr/bin:/bin",
        ],
        home: directory,
        keychainRead: { _ in credential },
        activeCLIProcesses: { _ in activity.next() },
        credentialReadAttempts: 1,
        retryDelay: .zero
      )
      Issue.record("A Claude process appearing during preservation should stop login")
    } catch let error as AccountLoginError {
      guard case .cliStillRunning(.claude, _) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func loginDoesNotLaunchWhenTheExistingCredentialCannotBeRead() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-unreadable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched")
    let executable = directory.appendingPathComponent("fake-claude")
    let script = """
    #!/bin/sh
    touch "$QUOTARI_TEST_MARKER"
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    do {
      _ = try await LiveClaudeAccountLogin.perform(
        environment: [
          "QUOTARI_CLAUDE_PATH": executable.path,
          "QUOTARI_TEST_MARKER": marker.path,
          "PATH": "/usr/bin:/bin",
        ],
        home: directory,
        keychainRead: { _ in
          throw KeychainItemStore.KeychainError.commandFailed(status: 36)
        },
        activeCLIProcesses: { _ in [] },
        credentialReadAttempts: 1,
        retryDelay: .zero
      )
      Issue.record("An unreadable live credential must stop login before the CLI launches")
    } catch let error as AccountLoginError {
      guard case .credentialReadFailed(.claude, _) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func loginDoesNotLaunchWhileAnotherClaudeProcessIsActive() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-active-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched")
    let executable = directory.appendingPathComponent("fake-claude")
    let script = """
    #!/bin/sh
    touch "$QUOTARI_TEST_MARKER"
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let credential = Data(
      #"{"claudeAiOauth":{"accessToken":"current","refreshToken":"current-refresh"}}"#.utf8
    )

    do {
      _ = try await LiveClaudeAccountLogin.perform(
        environment: [
          "QUOTARI_CLAUDE_PATH": executable.path,
          "QUOTARI_TEST_MARKER": marker.path,
          "PATH": "/usr/bin:/bin",
        ],
        home: directory,
        keychainRead: { _ in credential },
        activeCLIProcesses: { _ in ["claude (PID 42)"] },
        credentialReadAttempts: 1,
        retryDelay: .zero
      )
      Issue.record("An active Claude process must stop login before the CLI launches")
    } catch let error as AccountLoginError {
      guard case let .cliStillRunning(.claude, processes) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
      #expect(processes == ["claude (PID 42)"])
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func abandonedBrowserLoginTimesOutAndTerminatesTheCLI() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-claude")
    let script = """
    #!/bin/sh
    trap '' TERM
    while true; do :; done
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let credential = Data(
      #"{"claudeAiOauth":{"accessToken":"current","refreshToken":"current-refresh"}}"#.utf8
    )

    do {
      _ = try await LiveClaudeAccountLogin.perform(
        environment: ["QUOTARI_CLAUDE_PATH": executable.path, "PATH": "/usr/bin:/bin"],
        home: directory,
        keychainRead: { _ in credential },
        activeCLIProcesses: { _ in [] },
        credentialReadAttempts: 1,
        retryDelay: .zero,
        loginTimeout: .milliseconds(50)
      )
      Issue.record("An abandoned browser login should time out")
    } catch let error as AccountLoginError {
      guard case .loginTimedOut(.claude) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
    }
  }
}

private final class CredentialSequence: @unchecked Sendable {
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

private final class ClaudePayloadRecorder: @unchecked Sendable {
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

private final class ClaudeActivitySequence: @unchecked Sendable {
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

private func claudeCredential(accessToken: String, refreshToken: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
  )
}
