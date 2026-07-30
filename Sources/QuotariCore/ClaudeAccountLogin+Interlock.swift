import Foundation

extension LiveClaudeAccountLogin {
  static func resolvedProcessRecords(
    legacy: (@Sendable (UsageProvider) throws -> [String])?,
    records: @escaping @Sendable (UsageProvider) throws -> [CLIActivityProcess]
  ) -> @Sendable (UsageProvider) throws -> [CLIActivityProcess] {
    guard let legacy else { return records }
    return { provider in
      try legacy(provider).map(CLIActivityProcess.init(legacyDisplayName:))
    }
  }

  static func requireClaudeCLIInactive(
    _ activeCLIProcessRecords: @Sendable (UsageProvider) throws -> [CLIActivityProcess],
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot?
  ) throws {
    let active: [CLIActivityProcess]
    do {
      active = try activeCLIProcessRecords(.claude)
    } catch {
      throw AccountLoginError.cliActivityCheckFailed(.claude, underlying: error.localizedDescription)
    }
    let blocked = activitySnapshot?.unapprovedProcesses(
      for: .claude,
      activeProcesses: active
    ) ?? active.map(\.displayName)
    guard blocked.isEmpty else {
      throw AccountLoginError.cliStillRunning(.claude, processes: blocked)
    }
  }

  static func credentialAtOverwriteBoundary(
    keychainRead: @escaping @Sendable (String) throws -> Data?,
    activeCLIProcessRecords: @escaping @Sendable (UsageProvider) throws -> [CLIActivityProcess],
    beforeCredentialOverwrite: (@Sendable (Data?) async throws -> Void)?,
    allowingActiveSessions activitySnapshot: CLIActivitySnapshot?
  ) async throws -> Data? {
    try requireClaudeCLIInactive(
      activeCLIProcessRecords,
      allowingActiveSessions: activitySnapshot
    )
    var observed = try readClaudeKeychain(keychainRead)
    for _ in 0 ..< 3 {
      try await beforeCredentialOverwrite?(observed)
      try Task.checkCancellation()
      try requireClaudeCLIInactive(
        activeCLIProcessRecords,
        allowingActiveSessions: activitySnapshot
      )
      let current = try readClaudeKeychain(keychainRead)
      if current == observed {
        return current
      }
      observed = current
    }
    throw AccountLoginError.credentialChangedDuringPreparation(.claude)
  }

  static func readClaudeKeychain(
    _ keychainRead: @Sendable (String) throws -> Data?
  ) throws -> Data? {
    do {
      return try keychainRead(keychainService)
    } catch {
      throw AccountLoginError.credentialReadFailed(.claude, underlying: error.localizedDescription)
    }
  }
}
