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
    guard let previous, let installed else { return }
    try restoreClaudeKeychain(previous, replacing: installed, service: service)
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
