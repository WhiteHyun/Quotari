import Foundation
@testable import QuotariCore
import Testing

struct ClaudeAccountLoginCompletionTests {
  @Test func browserSuccessCompletesWhenAuthenticationCodePromptKeepsRunning() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-claude-browser-success-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-claude")
    let script = """
    #!/bin/sh
    printf 'Paste code here if prompted > Login successful.\n'
    trap '' TERM
    while true; do :; done
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let previous = completionCredential(accessToken: "previous", refreshToken: "previous-refresh")
    let added = completionCredential(accessToken: "added", refreshToken: "added-refresh")
    let credentials = CompletionCredentialSequence([previous, previous, added])

    let result = try await LiveClaudeAccountLogin.perform(
      environment: ["QUOTARI_CLAUDE_PATH": executable.path, "PATH": "/usr/bin:/bin"],
      home: directory,
      keychainRead: { _ in credentials.next() },
      activeCLIProcesses: { _ in [] },
      credentialReadAttempts: 1,
      retryDelay: .zero,
      loginTimeout: .seconds(5)
    )

    #expect(result.payload == added)
  }
}

private final class CompletionCredentialSequence: @unchecked Sendable {
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

private func completionCredential(accessToken: String, refreshToken: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
  )
}
