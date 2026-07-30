import Foundation

struct ClaudeLoginObservationContext: @unchecked Sendable {
  let environment: [String: String]
  let home: URL
  let fileManager: FileManager
  let keychainRead: @Sendable (String) throws -> Data?
  let observer: CredentialObservationHandler?

  func capture() -> ClaudeLoginCredentialObservation? {
    do {
      let accountStateURL = ClaudeCodeAccountState.configurationURL(environment: environment, home: home)
      let keychainPayload = try keychainRead(ClaudeCredentialsStore.keychainService)
      let accountState = try readAccountState(at: accountStateURL)
      guard try keychainRead(ClaudeCredentialsStore.keychainService) == keychainPayload,
            try readAccountState(at: accountStateURL) == accountState
      else { return nil }
      return ClaudeLoginCredentialObservation(
        keychainPayload: keychainPayload,
        accountState: accountState
      )
    } catch {
      // Without a trustworthy observation, recovery retains the existing
      // fail-closed behavior instead of guessing which credential to replace.
      return nil
    }
  }

  func capture(matching keychainPayload: Data) -> ClaudeLoginCredentialObservation? {
    guard let observation = capture(), observation.keychainPayload == keychainPayload else {
      return nil
    }
    return observation
  }

  func report() {
    report(capture())
  }

  func report(_ observation: ClaudeLoginCredentialObservation?) {
    guard let observer, let observation else { return }
    observer(observation)
  }

  private func readAccountState(at url: URL) throws -> Data? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }
}

extension LiveClaudeAccountLogin {
  static func runLoginCommandReportingCredential(
    configuration: AccountLoginConfiguration,
    executable: URL,
    timeout: Duration,
    observers: AccountLoginCommandObservers,
    observation: ClaudeLoginObservationContext
  ) async throws -> Int32 {
    do {
      let status = try await runLoginCommand(
        configuration: configuration,
        executable: executable,
        environment: observation.environment,
        timeout: timeout,
        observers: observers
      )
      observation.report()
      return status
    } catch {
      observation.report()
      throw error
    }
  }
}
