import Foundation
@testable import QuotariCore
import Testing

extension ClaudeActiveSessionRotationTests {
  @Test func drainsSampledRotationsBeforeReportingANewProcess() async throws {
    let fixture = try RotationLoginFixture()
    defer { fixture.remove() }
    let original = rotationCredential(accessToken: "original", refreshToken: "original-refresh")
    let firstRotation = rotationCredential(accessToken: "first", refreshToken: "first-refresh")
    let queuedRotation = rotationCredential(accessToken: "queued", refreshToken: "queued-refresh")
    let keychain = RotationCredentialBox(original)
    let preserved = RotationCredentialRecorder()
    let gate = RotationPreservationGate(blocking: firstRotation)
    defer { gate.release() }
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
    keychain.value = queuedRotation
    try await waitForRotationCondition { keychain.readValues.contains(queuedRotation) }
    activity.value = [approved, unapproved]
    try await Task.sleep(for: .milliseconds(20))
    gate.release()

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
    #expect(preserved.values.contains(firstRotation))
    #expect(preserved.values.contains(queuedRotation))
  }
}
