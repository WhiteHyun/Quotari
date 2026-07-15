import Foundation
@testable import QuotariCore
import Testing

struct AccountLoginServiceTests {
  @Test func productionServiceOnlyAdvertisesSafelyIsolatedProviders() {
    let service = AccountLoginService()

    #expect(service.supports(provider: .codex))
    #expect(!service.supports(provider: .claude))
    #expect(service.unavailableReason(provider: .claude) != nil)
  }

  @Test func codexLoginUsesAnIsolatedCodexHome() throws {
    let root = URL(fileURLWithPath: "/tmp/quotari-login", isDirectory: true)

    let configuration = try IsolatedAccountLogin.configuration(provider: .codex, root: root)

    #expect(configuration.executableName == "codex")
    #expect(configuration.arguments == ["login", "--config", #"cli_auth_credentials_store="file""#])
    #expect(configuration.isolatedEnvironment == ["CODEX_HOME": "/tmp/quotari-login/codex"])
    #expect(configuration.credentialURL.path == "/tmp/quotari-login/codex/auth.json")
    #expect(configuration.origin == .codexAuthFile(path: configuration.credentialURL.path))
  }

  @Test func explicitExecutableOverrideTakesPrecedenceOverPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-test-\(UUID().uuidString)", isDirectory: true)
    let pathDirectory = directory.appendingPathComponent("path", isDirectory: true)
    let overrideDirectory = directory.appendingPathComponent("override", isDirectory: true)
    try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pathExecutable = pathDirectory.appendingPathComponent("codex")
    let overrideExecutable = overrideDirectory.appendingPathComponent("custom-codex")
    try Data().write(to: pathExecutable)
    try Data().write(to: overrideExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pathExecutable.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: overrideExecutable.path)
    let configuration = try IsolatedAccountLogin.configuration(provider: .codex, root: directory)

    let resolved = IsolatedAccountLogin.executableURL(
      for: configuration,
      environment: [
        "PATH": pathDirectory.path,
        "QUOTARI_CODEX_PATH": overrideExecutable.path,
      ],
      home: directory
    )

    #expect(resolved == overrideExecutable)
  }

  @Test func injectedOperationReturnsItsCredential() async throws {
    let expected = AccountLoginResult(
      provider: .codex,
      origin: .codexAuthFile(path: "/tmp/auth.json"),
      payload: Data("credential".utf8)
    )
    let service = AccountLoginService { provider in
      #expect(provider == .codex)
      return expected
    }

    let result = try await service.login(provider: .codex)

    #expect(result.provider == expected.provider)
    #expect(result.origin == expected.origin)
    #expect(result.payload == expected.payload)
  }

  @Test func isolatedLoginImportsCredentialAndRemovesTemporaryHome() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let script = """
    #!/bin/sh
    [ "$1" = "login" ] || exit 10
    [ "$2" = "--config" ] || exit 11
    [ "$3" = 'cli_auth_credentials_store="file"' ] || exit 12
    mkdir -p "$CODEX_HOME"
    printf '%s' '{"tokens":{"access_token":"added","account_id":"account","refresh_token":"refresh"}}' \
      > "$CODEX_HOME/auth.json"
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let result = try await IsolatedAccountLogin.perform(
      provider: .codex,
      environment: ["QUOTARI_CODEX_PATH": executable.path, "PATH": "/usr/bin:/bin"],
      home: directory,
      temporaryDirectory: directory
    )

    #expect(result.provider == .codex)
    #expect(String(data: result.payload, encoding: .utf8)?.contains("added") == true)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("Quotari-AddAccount-") }
    #expect(leftovers.isEmpty)
  }

  @Test func claudeLoginFailsClosedBeforeLaunchingCLI() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-\(UUID().uuidString)", isDirectory: true)
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
      _ = try await IsolatedAccountLogin.perform(
        provider: .claude,
        environment: [
          "QUOTARI_CLAUDE_PATH": executable.path,
          "QUOTARI_TEST_MARKER": marker.path,
          "PATH": "/usr/bin:/bin",
        ],
        home: directory,
        temporaryDirectory: directory
      )
      Issue.record("Claude login should fail closed")
    } catch let error as AccountLoginError {
      guard case .isolatedLoginUnavailable(.claude) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
    }

    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("Quotari-AddAccount-") }
    #expect(leftovers.isEmpty)
  }

  @Test func failedLoginDoesNotLeaveTemporaryHome() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    try Data("#!/bin/sh\nexit 7\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    await #expect(throws: AccountLoginError.self) {
      try await IsolatedAccountLogin.perform(
        provider: .codex,
        environment: ["QUOTARI_CODEX_PATH": executable.path, "PATH": "/usr/bin:/bin"],
        home: directory,
        temporaryDirectory: directory
      )
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("Quotari-AddAccount-") }
    #expect(leftovers.isEmpty)
  }

  @Test func cancellationTerminatesLoginAndRemovesTemporaryHome() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("started")
    let executable = directory.appendingPathComponent("fake-codex")
    let script = """
    #!/bin/sh
    touch "$QUOTARI_TEST_MARKER"
    exec /bin/sleep 30
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let task = Task {
      try await IsolatedAccountLogin.perform(
        provider: .codex,
        environment: [
          "QUOTARI_CODEX_PATH": executable.path,
          "QUOTARI_TEST_MARKER": marker.path,
          "PATH": "/usr/bin:/bin",
        ],
        home: directory,
        temporaryDirectory: directory
      )
    }
    for _ in 0 ..< 500 where !FileManager.default.fileExists(atPath: marker.path) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))

    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("Quotari-AddAccount-") }
    #expect(leftovers.isEmpty)
  }

  @Test func cleanupFailureDoesNotReturnTemporaryCredential() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-cleanup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let executable = directory.appendingPathComponent("fake-codex")
    let script = """
    #!/bin/sh
    mkdir -p "$CODEX_HOME"
    printf '%s' '{"tokens":{"access_token":"added","account_id":"account","refresh_token":"refresh"}}' \
      > "$CODEX_HOME/auth.json"
    chmod 500 "$QUOTARI_TEST_TEMPORARY_DIRECTORY"
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    do {
      _ = try await IsolatedAccountLogin.perform(
        provider: .codex,
        environment: [
          "QUOTARI_CODEX_PATH": executable.path,
          "QUOTARI_TEST_TEMPORARY_DIRECTORY": directory.path,
          "PATH": "/usr/bin:/bin",
        ],
        home: directory,
        temporaryDirectory: directory
      )
      Issue.record("Credential should not be returned when cleanup fails")
    } catch let error as AccountLoginError {
      guard case .temporaryCredentialCleanupFailed(.codex) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
    }
  }
}
