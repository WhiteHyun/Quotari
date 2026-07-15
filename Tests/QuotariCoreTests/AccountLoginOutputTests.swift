import Foundation
@testable import QuotariCore
import Testing

struct AccountLoginOutputTests {
  @Test func loginStreamsManualAuthenticationGuidanceWhileCommandIsRunning() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-output-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let continueMarker = directory.appendingPathComponent("continue")
    let executable = directory.appendingPathComponent("fake-codex")
    let script = """
    #!/bin/sh
    echo 'If your browser did not open, visit https://example.com/device' >&2
    while [ ! -f "$QUOTARI_CONTINUE_MARKER" ]; do /bin/sleep 0.01; done
    mkdir -p "$CODEX_HOME"
    printf '%s' '{"tokens":{"access_token":"added","account_id":"account","refresh_token":"refresh"}}' \
      > "$CODEX_HOME/auth.json"
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let recorder = AccountLoginOutputRecorder()
    let task = Task {
      try await IsolatedAccountLogin.perform(
        provider: .codex,
        environment: [
          "QUOTARI_CODEX_PATH": executable.path,
          "QUOTARI_CONTINUE_MARKER": continueMarker.path,
          "PATH": "/usr/bin:/bin",
        ],
        home: directory,
        temporaryDirectory: directory,
        onOutput: { output in await recorder.append(output) }
      )
    }

    for _ in 0 ..< 100 where await !(recorder.output.contains("https://example.com/device")) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await recorder.output.contains("If your browser did not open"))
    try Data().write(to: continueMarker)

    let result = try await task.value
    #expect(result.provider == .codex)
  }
}

private actor AccountLoginOutputRecorder {
  private(set) var output = ""

  func append(_ chunk: String) {
    output += chunk
  }
}
