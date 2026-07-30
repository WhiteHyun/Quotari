import Foundation

struct ClaudeLoginRuntime {
  let configuration: AccountLoginConfiguration
  let executable: URL
  let observation: ClaudeLoginObservationContext
}

extension LiveClaudeAccountLogin {
  static func loginRuntime(
    environment: [String: String],
    home: URL,
    fileManager: FileManager,
    keychainRead: @escaping @Sendable (String) throws -> Data?,
    observer: CredentialObservationHandler?
  ) throws -> ClaudeLoginRuntime {
    let configuration = configuration(home: home)
    guard let executable = IsolatedAccountLogin.executableURL(
      for: configuration,
      environment: environment,
      home: home,
      fileManager: fileManager
    ) else {
      throw AccountLoginError.executableNotFound(.claude)
    }
    return ClaudeLoginRuntime(
      configuration: configuration,
      executable: executable,
      observation: ClaudeLoginObservationContext(
        environment: environment,
        home: home,
        fileManager: fileManager,
        keychainRead: keychainRead,
        observer: observer
      )
    )
  }
}
