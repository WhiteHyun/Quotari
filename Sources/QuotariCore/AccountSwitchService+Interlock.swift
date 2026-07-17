import Foundation

extension AccountSwitchService {
  struct ClaudeCredentialInstallation {
    var service: String
    var fileURL: URL
    var previous: ResolvedClaudeLivePayloads
    var replacement: ResolvedClaudeLivePayloads
  }

  func requireCLIInactive(_ provider: UsageProvider) throws {
    let active: [String]
    do {
      active = try activeCLIProcesses(provider)
    } catch {
      throw AccountSwitchError.cliActivityCheckFailed(underlying: error.localizedDescription)
    }
    guard active.isEmpty else {
      throw AccountSwitchError.cliStillRunning(processes: active)
    }
  }

  /// Restores the exact Keychain state observed immediately before Claude's
  /// browser login started. Before replacing a different renewable credential,
  /// it saves that credential to Quotari: a cancelled or failed CLI command can
  /// still have completed a token rotation, and that pair may be the account's
  /// only usable generation. The compare-before-write helpers leave a
  /// concurrently changed credential untouched.
  public func restoreClaudeLoginKeychain(to previous: Data?) throws {
    try restoreClaudeLoginKeychain(to: previous, expectation: .preserveInstalledCredential)
  }

  /// Restores only when the keychain still contains the exact generation
  /// observed when Quotari's login attempt ended. This permits rollback of an
  /// unrenewable failed-login payload without discarding a later external login.
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
    let canSkipUnrenewableBackup = if case .replaceObservedCredential = expectation {
      true
    } else {
      false
    }
    if !canSkipUnrenewableBackup
      || installed.map({
        ProviderCredentialMinimizer.minimize(provider: .claude, payload: $0) != nil
      }) == true {
      try backUp(
        provider: .claude,
        payload: installed,
        origin: .claudeKeychain(service: service),
        now: Date()
      )
    }
    switch (previous, installed) {
    case let (previous?, installed?):
      try restoreClaudeKeychain(previous, replacing: installed, service: service)
    case let (previous?, nil):
      // The CLI is a separate process and Keychain has no compare-and-swap.
      // Narrow the empty-slot race with the same activity/read interlock used
      // by normal switches immediately before recreating the item.
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

  private enum ClaudeLoginRecoveryExpectation {
    case preserveInstalledCredential
    case replaceObservedCredential(Data?)
  }

  func installClaudeCredentials(_ installation: ClaudeCredentialInstallation) throws {
    let preparedFile = try prepareCredentialFile(
      installation.replacement.file,
      replacing: installation.fileURL
    )
    defer { secureFileWriter.discard(preparedFile) }
    try requireCLIInactive(.claude)
    try verifyClaudeSlots(
      service: installation.service,
      fileURL: installation.fileURL,
      expectedKeychain: installation.previous.keychain,
      expectedFile: installation.previous.file
    )
    if let replacementKeychain = installation.replacement.keychain {
      try writeClaudeKeychain(
        replacementKeychain,
        replacing: installation.previous.keychain,
        service: installation.service
      )
    }
    if let preparedFile {
      try commitClaudeFile(preparedFile, installation: installation)
    }
    try verifyAppliedClaudeSlots(installation)
  }

  private func commitClaudeFile(
    _ preparedFile: URL,
    installation: ClaudeCredentialInstallation
  ) throws {
    do {
      try requireCLIInactive(.claude)
    } catch {
      if installation.replacement.keychain != nil {
        throw AccountSwitchError.partialSwitch(underlying: error.localizedDescription)
      }
      throw error
    }
    if let replacementKeychain = installation.replacement.keychain,
       try readClaudeKeychainAfterMutation(
         installation.service,
         context: "Claude's keychain couldn't be verified before the file update."
       ) != replacementKeychain {
      throw AccountSwitchError.partialSwitch(
        underlying: "Claude's keychain changed after Quotari wrote it; the newer value was left untouched."
      )
    }
    let observedFile = try readClaudeFileBeforeCommit(installation)
    guard observedFile == installation.previous.file else {
      try restoreClaudeKeychainIfNeeded(
        installation.previous.keychain,
        replacing: installation.replacement.keychain,
        service: installation.service
      )
      throw AccountSwitchError.concurrentCredentialChange
    }
    do {
      try secureFileWriter.commit(preparedFile, replacing: installation.fileURL)
    } catch {
      try restoreClaudeKeychainIfNeeded(
        installation.previous.keychain,
        replacing: installation.replacement.keychain,
        service: installation.service
      )
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
  }

  private func readClaudeFileBeforeCommit(
    _ installation: ClaudeCredentialInstallation
  ) throws -> Data? {
    guard installation.replacement.keychain != nil else {
      return try readFile(installation.fileURL)
    }
    do {
      return try readFile(installation.fileURL)
    } catch {
      let readError = error
      try restoreClaudeKeychainIfNeeded(
        installation.previous.keychain,
        replacing: installation.replacement.keychain,
        service: installation.service
      )
      throw AccountSwitchError.writeFailed(
        underlying: "Claude's credentials file couldn't be verified after the keychain update; "
          + "the keychain update was rolled back: \(readError.localizedDescription)"
      )
    }
  }

  private func restoreClaudeKeychainIfNeeded(
    _ previous: Data?,
    replacing installed: Data?,
    service: String
  ) throws {
    guard let installed else { return }
    if let previous {
      try restoreClaudeKeychain(previous, replacing: installed, service: service)
    } else {
      try removeCreatedClaudeKeychain(replacing: installed, service: service)
    }
  }

  private func verifyClaudeSlots(
    service: String,
    fileURL: URL,
    expectedKeychain: Data?,
    expectedFile: Data?
  ) throws {
    guard try readKeychain(service) == expectedKeychain,
          try readFile(fileURL) == expectedFile
    else { throw AccountSwitchError.concurrentCredentialChange }
  }

  private func writeClaudeKeychain(
    _ payload: Data,
    replacing previous: Data?,
    service: String
  ) throws {
    do {
      try keychainWrite(payload, service)
    } catch {
      let writeError = error
      let observed = try readClaudeKeychainAfterMutation(
        service,
        context: "Claude's keychain write result couldn't be verified."
      )
      if observed == payload {
        return
      }
      guard observed == previous else {
        throw AccountSwitchError.partialSwitch(underlying: writeError.localizedDescription)
      }
      throw AccountSwitchError.writeFailed(underlying: writeError.localizedDescription)
    }
    guard try readClaudeKeychainAfterMutation(
      service,
      context: "Claude's keychain write result couldn't be verified."
    ) == payload else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Claude's keychain changed while Quotari's write was being verified."
      )
    }
  }

  private func restoreClaudeKeychain(
    _ previous: Data,
    replacing installed: Data,
    service: String
  ) throws {
    do {
      try requireCLIInactive(.claude)
    } catch {
      throw AccountSwitchError.partialSwitch(underlying: error.localizedDescription)
    }
    guard try readClaudeKeychainAfterMutation(
      service,
      context: "Claude's keychain couldn't be verified before rollback."
    ) == installed else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Claude's keychain changed after Quotari's write; the newer value was left untouched."
      )
    }
    var operationError: Error?
    do {
      try keychainWrite(previous, service)
    } catch {
      operationError = error
    }
    guard try readClaudeKeychainAfterMutation(
      service,
      context: "Claude's keychain rollback couldn't be verified."
    ) == previous else {
      throw AccountSwitchError.partialSwitch(
        underlying: operationError?.localizedDescription
          ?? "Claude's previous keychain value couldn't be restored."
      )
    }
  }

  private func removeCreatedClaudeKeychain(
    replacing installed: Data,
    service: String
  ) throws {
    do {
      try requireCLIInactive(.claude)
    } catch {
      throw AccountSwitchError.partialSwitch(underlying: error.localizedDescription)
    }
    guard try readClaudeKeychainAfterMutation(
      service,
      context: "Claude's keychain couldn't be verified before rollback."
    ) == installed else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Claude's keychain changed after Quotari's write; the newer value was left untouched."
      )
    }
    var operationError: Error?
    do {
      try keychainDelete(service)
    } catch {
      operationError = error
    }
    guard try readClaudeKeychainAfterMutation(
      service,
      context: "Claude's keychain rollback couldn't be verified."
    ) == nil else {
      throw AccountSwitchError.partialSwitch(
        underlying: operationError?.localizedDescription
          ?? "Claude's newly created keychain value couldn't be removed."
      )
    }
  }

  private func verifyAppliedClaudeSlots(_ installation: ClaudeCredentialInstallation) throws {
    if try readClaudeKeychainAfterMutation(
      installation.service,
      context: "Claude's final keychain state couldn't be verified."
    ) != installation.replacement.keychain {
      throw AccountSwitchError.partialSwitch(
        underlying: "Claude's keychain changed after the switch; the newer value was left untouched."
      )
    }
    let observedFile: Data?
    do {
      observedFile = try readFile(installation.fileURL)
    } catch {
      let readError = error
      try restoreClaudeKeychainIfNeeded(
        installation.previous.keychain,
        replacing: installation.replacement.keychain,
        service: installation.service
      )
      throw AccountSwitchError.writeFailed(
        underlying: "Claude's final credentials-file state couldn't be verified; "
          + "the keychain update was rolled back: \(readError.localizedDescription)"
      )
    }
    guard observedFile == installation.replacement.file else {
      try restoreClaudeKeychainIfNeeded(
        installation.previous.keychain,
        replacing: installation.replacement.keychain,
        service: installation.service
      )
      throw AccountSwitchError.concurrentCredentialChange
    }
  }

  private func readClaudeKeychainAfterMutation(
    _ service: String,
    context: String
  ) throws -> Data? {
    do {
      return try readKeychain(service)
    } catch {
      throw AccountSwitchError.partialSwitch(underlying: "\(context) \(error.localizedDescription)")
    }
  }
}
