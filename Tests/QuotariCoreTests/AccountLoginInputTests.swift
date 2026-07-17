import Foundation
@testable import QuotariCore
import Testing

struct AccountLoginInputTests {
  @Test func forwardsAuthenticationCodeToStandardInput() async throws {
    let input = AccountLoginInput()
    let task = Task {
      try await IsolatedAccountLogin.runLoginCommand(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", #"IFS= read -r code; [ "$code" = "auth-code-123" ]"#],
        environment: [:],
        currentDirectory: FileManager.default.temporaryDirectory,
        observers: AccountLoginCommandObservers(input: input)
      )
    }
    for _ in 0 ..< 100 {
      guard !input.isConnected else { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(input.isConnected)
    try input.submit(authenticationCode: "  auth-code-123  ")
    #expect(try await task.value == 0)
    #expect(throws: AccountLoginInputError.self) {
      try input.submit(authenticationCode: "another-code")
    }
  }

  @Test func rejectsAnEmptyAuthenticationCode() {
    let input = AccountLoginInput()

    #expect(throws: AccountLoginInputError.self) {
      try input.submit(authenticationCode: "  \n")
    }
  }

  @Test func rejectsEmbeddedLineBreaks() {
    let input = AccountLoginInput()

    #expect(throws: AccountLoginInputError.multilineAuthenticationCode) {
      try input.submit(authenticationCode: "first-line\nsecond-line")
    }
  }

  @Test func closedProcessInputFailsWithoutTerminatingTheApp() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-login-closed-input-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("stdin-closed")
    let input = AccountLoginInput()
    let task = Task {
      try await IsolatedAccountLogin.runLoginCommand(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exec 0<&-; touch \"$QUOTARI_TEST_MARKER\"; sleep 1"],
        environment: ["QUOTARI_TEST_MARKER": marker.path],
        currentDirectory: directory,
        observers: AccountLoginCommandObservers(input: input)
      )
    }
    for _ in 0 ..< 100 {
      guard !FileManager.default.fileExists(atPath: marker.path) else { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(throws: AccountLoginInputError.inputUnavailable) {
      try input.submit(authenticationCode: "auth-code")
    }
    #expect(try await task.value == 0)
  }
}
