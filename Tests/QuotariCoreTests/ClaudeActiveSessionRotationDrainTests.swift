import Foundation
@testable import QuotariCore
import Testing

extension ClaudeActiveSessionRotationTests {
  @Test func cancellationDoesNotInterruptQueuedRotationPreservation() async throws {
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
        duringLoginCredentialChange: {
          try Task.checkCancellation()
          preserved.append($0)
          await gate.pauseIfNeeded($0)
          try Task.checkCancellation()
        },
        allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: [approved])
      )
    }
    try await waitForRotationCondition { FileManager.default.fileExists(atPath: fixture.started.path) }

    keychain.value = firstRotation
    try await waitForRotationCondition { gate.isWaiting }
    keychain.value = queuedRotation
    try await waitForRotationCondition { keychain.readValues.contains(queuedRotation) }
    login.cancel()
    gate.release()

    do {
      _ = try await login.value
      Issue.record("Cancelling the login should still report cancellation")
    } catch is CancellationError {
      // Expected after every observed credential generation is durable.
    }
    #expect(preserved.values.contains(firstRotation))
    #expect(preserved.values.contains(queuedRotation))
  }

  @Test func monitorsActivityUntilTheDelayedCredentialIsVisible() async throws {
    let fixture = try RotationLoginFixture()
    defer { fixture.remove() }
    let original = rotationCredential(accessToken: "original", refreshToken: "original-refresh")
    let keychain = RotationCredentialBox(original)
    let readsAfterCommand = RotationCounter()
    let approved = rotationProcess(pid: 42, generation: 1)
    let unapproved = rotationProcess(pid: 99, generation: 2)
    let activity = RotationActivityBox([approved])

    let login = Task {
      try await LiveClaudeAccountLogin.perform(
        environment: fixture.environment,
        home: fixture.directory,
        keychainRead: { _ in
          if FileManager.default.fileExists(atPath: fixture.finished.path) {
            readsAfterCommand.increment()
          }
          return keychain.value
        },
        activeCLIProcessRecords: { _ in activity.value + fixture.loginProcessRecords },
        credentialReadAttempts: 50,
        retryDelay: .milliseconds(20),
        loginTimeout: .seconds(2),
        activityInspectionInterval: .milliseconds(5),
        allowingActiveSessions: CLIActivitySnapshot(provider: .claude, processes: [approved])
      )
    }
    try await waitForRotationCondition { FileManager.default.fileExists(atPath: fixture.started.path) }
    try Data().write(to: fixture.release)
    try await waitForRotationCondition { readsAfterCommand.value > 0 }
    activity.value = [approved, unapproved]

    do {
      _ = try await login.value
      Issue.record("A process launched while waiting for the credential should stop login")
    } catch let error as AccountLoginError {
      guard case let .cliStillRunning(.claude, processes) = error else {
        Issue.record("Unexpected login error: \(error)")
        return
      }
      #expect(processes == ["claude (PID 99)"])
    }
  }

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
