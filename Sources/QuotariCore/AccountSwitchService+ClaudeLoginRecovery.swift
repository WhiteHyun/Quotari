import Foundation

extension AccountSwitchService {
  struct ClaudeLoginRecovery {
    var service: String
    var accountStateURL: URL
    var previousKeychain: Data?
    var installedKeychain: Data?
    var previousAccountState: Data?
    var installedAccountState: Data?

    var restoresKeychain: Bool {
      installedKeychain != previousKeychain
    }

    var restoresAccountState: Bool {
      installedAccountState != previousAccountState
    }

    var isNeeded: Bool {
      restoresKeychain || restoresAccountState
    }
  }

  private enum ClaudeLoginRecoveryExpectation {
    case preserveInstalledCredential
    case replaceObservedCredential(Data?)

    var permitsUnrenewableCredential: Bool {
      if case .replaceObservedCredential = self {
        return true
      }
      return false
    }
  }

  /// Restores only the Keychain slot for callers that intentionally do not
  /// own Claude's account-state file.
  public func restoreClaudeLoginKeychain(to previous: Data?) throws {
    try restoreClaudeLoginKeychain(to: previous, expectation: .preserveInstalledCredential)
  }

  /// Restores only when the Keychain still contains the exact generation
  /// observed when Quotari's login process ended.
  public func restoreClaudeLoginKeychain(
    to previous: Data?,
    replacing observedPostLogin: Data?
  ) throws {
    try restoreClaudeLoginKeychain(
      to: previous,
      expectation: .replaceObservedCredential(observedPostLogin)
    )
  }

  private func restoreClaudeLoginKeychain(
    to previous: Data?,
    expectation: ClaudeLoginRecoveryExpectation
  ) throws {
    let service = ClaudeCredentialsStore.keychainService
    try requireCLIInactive(.claude)
    let installed = try readKeychain(service)
    guard installed != previous else { return }
    if case let .replaceObservedCredential(observed) = expectation,
       installed != observed {
      throw AccountSwitchError.concurrentCredentialChange
    }
    try backUpPostLoginCredential(
      installed,
      service: service,
      expectation: expectation
    )
    try restoreClaudeKeychainSlot(previous, replacing: installed, service: service)
  }

  public func claudeAccountStateSnapshot() throws -> Data? {
    try readFile(ClaudeCodeAccountState.configurationURL(environment: environment, home: home))
  }

  /// Restores the exact shared Claude login state observed immediately before
  /// browser authentication. Account state is committed last; if its CAS or
  /// write fails, the Keychain returns to the post-login value.
  public func restoreClaudeLogin(
    keychain previousKeychain: Data?,
    accountState previousAccountState: Data?
  ) throws {
    try restoreClaudeLogin(
      keychain: previousKeychain,
      accountState: previousAccountState,
      expectation: .preserveInstalledCredential
    )
  }

  /// Restores both shared Claude slots only while the Keychain still matches
  /// the generation observed when Quotari's login process ended.
  public func restoreClaudeLogin(
    keychain previousKeychain: Data?,
    replacing observedPostLogin: Data?,
    accountState previousAccountState: Data?
  ) throws {
    try restoreClaudeLogin(
      keychain: previousKeychain,
      accountState: previousAccountState,
      expectation: .replaceObservedCredential(observedPostLogin)
    )
  }

  private func restoreClaudeLogin(
    keychain previousKeychain: Data?,
    accountState previousAccountState: Data?,
    expectation: ClaudeLoginRecoveryExpectation
  ) throws {
    let recovery = try claudeLoginRecovery(
      previousKeychain: previousKeychain,
      previousAccountState: previousAccountState,
      expectation: expectation
    )
    guard recovery.isNeeded else { return }
    if recovery.restoresKeychain {
      try backUpPostLoginCredential(
        recovery.installedKeychain,
        service: recovery.service,
        expectation: expectation
      )
    }
    let preparedAccountState = try prepareCredentialFile(
      recovery.restoresAccountState ? recovery.previousAccountState : nil,
      replacing: recovery.accountStateURL
    )
    defer { secureFileWriter.discard(preparedAccountState) }
    try verifyClaudeLoginRecoveryBoundary(recovery, expectedKeychain: recovery.installedKeychain)
    if recovery.restoresKeychain {
      try restoreClaudeKeychainSlot(
        recovery.previousKeychain,
        replacing: recovery.installedKeychain,
        service: recovery.service
      )
    }
    try commitClaudeLoginAccountState(preparedAccountState, recovery: recovery)
  }

  private func claudeLoginRecovery(
    previousKeychain: Data?,
    previousAccountState: Data?,
    expectation: ClaudeLoginRecoveryExpectation
  ) throws -> ClaudeLoginRecovery {
    let service = ClaudeCredentialsStore.keychainService
    let accountStateURL = ClaudeCodeAccountState.configurationURL(environment: environment, home: home)
    try requireCLIInactive(.claude)
    let installedKeychain = try readKeychain(service)
    if case let .replaceObservedCredential(observed) = expectation,
       installedKeychain != observed {
      throw AccountSwitchError.concurrentCredentialChange
    }
    return try ClaudeLoginRecovery(
      service: service,
      accountStateURL: accountStateURL,
      previousKeychain: previousKeychain,
      installedKeychain: installedKeychain,
      previousAccountState: previousAccountState,
      installedAccountState: readFile(accountStateURL)
    )
  }

  private func backUpPostLoginCredential(
    _ payload: Data?,
    service: String,
    expectation: ClaudeLoginRecoveryExpectation
  ) throws {
    // Browser login can replace the Keychain credential before Claude Code
    // refreshes ~/.claude.json. Without a profile fetched from this exact
    // access token, the two stores are not proof of the same identity.
    if expectation.permitsUnrenewableCredential,
       payload.map({
         ProviderCredentialMinimizer.minimize(provider: .claude, payload: $0) == nil
       }) ?? true {
      return
    }
    try backUp(
      provider: .claude,
      payload: payload,
      origin: .claudeKeychain(service: service),
      now: Date()
    )
  }

  private func verifyClaudeLoginRecoveryBoundary(
    _ recovery: ClaudeLoginRecovery,
    expectedKeychain: Data?
  ) throws {
    try requireCLIInactive(.claude)
    guard try readKeychain(recovery.service) == expectedKeychain,
          try readFile(recovery.accountStateURL) == recovery.installedAccountState
    else { throw AccountSwitchError.concurrentCredentialChange }
  }

  private func commitClaudeLoginAccountState(
    _ preparedAccountState: URL?,
    recovery: ClaudeLoginRecovery
  ) throws {
    do {
      try verifyClaudeLoginRecoveryBoundary(recovery, expectedKeychain: recovery.previousKeychain)
      if let preparedAccountState {
        try secureFileWriter.commit(preparedAccountState, replacing: recovery.accountStateURL)
      } else if recovery.restoresAccountState {
        try secureFileWriter.remove(recovery.accountStateURL)
      }
    } catch {
      let accountStateError = error
      try rollBackClaudeLoginKeychain(recovery, after: accountStateError)
    }
  }

  private func rollBackClaudeLoginKeychain(
    _ recovery: ClaudeLoginRecovery,
    after accountStateError: Error
  ) throws -> Never {
    do {
      if recovery.restoresKeychain {
        try restoreClaudeKeychainSlot(
          recovery.installedKeychain,
          replacing: recovery.previousKeychain,
          service: recovery.service
        )
      }
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: "Claude's account-state recovery failed and its keychain rollback also failed: "
          + error.localizedDescription
      )
    }
    if let switchError = accountStateError as? AccountSwitchError {
      throw switchError
    }
    throw AccountSwitchError.writeFailed(underlying: accountStateError.localizedDescription)
  }

  private func restoreClaudeKeychainSlot(
    _ previous: Data?,
    replacing installed: Data?,
    service: String
  ) throws {
    switch (previous, installed) {
    case let (previous?, installed?):
      try restoreClaudeKeychain(previous, replacing: installed, service: service)
    case let (previous?, nil):
      try requireCLIInactive(.claude)
      guard try readKeychain(service) == nil else {
        throw AccountSwitchError.concurrentCredentialChange
      }
      try writeClaudeKeychain(previous, replacing: nil, service: service)
    case let (nil, installed?):
      try removeCreatedClaudeKeychain(replacing: installed, service: service)
    case (nil, nil):
      return
    }
  }
}
