import Foundation

extension AccountSwitchService {
  func installCodexKeychain(
    _ payload: Data,
    replacing previous: Data?,
    _ storage: CodexAuthStorage,
    expectedFilePayload: Data?,
    now: Date
  ) throws {
    let fallback = try prepareCodexFallbackTransition(
      storage,
      expectedPayload: expectedFilePayload,
      now: now
    )
    do {
      try writeCodexKeychain(payload, replacing: previous, storage: storage)
    } catch {
      let writeError = error
      do {
        try restoreCodexFallback(fallback, storage: storage)
      } catch {
        throw AccountSwitchError.partialSwitch(
          underlying: "The Codex keychain write failed and its fallback couldn't be restored: "
            + "\(writeError.localizedDescription) \(error.localizedDescription)"
        )
      }
      throw writeError
    }
    try finalizeCodexKeychainInstallation(
      payload,
      replacing: previous,
      storage: storage,
      fallback: fallback,
      now: now
    )
  }

  private func prepareCodexFallbackTransition(
    _ storage: CodexAuthStorage,
    expectedPayload: Data?,
    now: Date
  ) throws -> CodexFallbackTransition {
    var transition = CodexFallbackTransition(expectedPayload: expectedPayload)
    guard let expectedPayload,
          CodexAuthStorage.canRemoveFallback(expectedPayload)
    else { return transition }

    try requireCLIInactive(.codex)
    let quarantineURL = storage.authFileURL.deletingLastPathComponent()
      .appendingPathComponent(".auth.json.quotari-quarantine.\(UUID().uuidString)")
    do {
      try FileManager.default.moveItem(at: storage.authFileURL, to: quarantineURL)
    } catch {
      throw AccountSwitchError.writeFailed(
        underlying: "Codex's fallback file couldn't be quarantined safely: " + error.localizedDescription
      )
    }
    transition.quarantineURL = quarantineURL

    let quarantined: Data?
    do {
      quarantined = try readFile(quarantineURL)
    } catch {
      try restoreCodexFallback(transition, storage: storage)
      throw error
    }
    guard quarantined == expectedPayload else {
      try rejectChangedCodexQuarantine(
        quarantined,
        transition: transition,
        storage: storage,
        now: now
      )
    }

    let source = ProviderCredentialSource.codexAuthFile(path: storage.authFileURL.path)
    let replacement: Data?
    do {
      replacement = try storage.payload(for: source)
    } catch {
      try restoreCodexFallback(transition, storage: storage)
      throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
    }
    if let replacement {
      try rejectCodexFallbackReplacement(
        replacement,
        transition: transition,
        storage: storage,
        now: now
      )
    }
    return transition
  }

  private func rejectCodexFallbackReplacement(
    _ replacement: Data,
    transition: CodexFallbackTransition,
    storage: CodexAuthStorage,
    now: Date
  ) throws -> Never {
    do {
      try backUp(
        provider: .codex,
        payload: replacement,
        origin: .codexAuthFile(path: storage.authFileURL.path),
        now: now
      )
    } catch {
      let backupError = error
      do {
        try discardCodexFallback(transition)
      } catch {
        throw AccountSwitchError.writeFailed(
          underlying: "Codex's replacement fallback couldn't be backed up "
            + "(\(backupError.localizedDescription)); the prior fallback remains recoverable at "
            + "\(transition.quarantineURL?.path ?? "the quarantine path") because cleanup failed "
            + "(\(error.localizedDescription))."
        )
      }
      throw backupError
    }
    try discardCodexFallback(transition)
    throw AccountSwitchError.concurrentCredentialChange
  }

  private func finalizeCodexKeychainInstallation(
    _ installed: Data,
    replacing previous: Data?,
    storage: CodexAuthStorage,
    fallback: CodexFallbackTransition,
    now: Date
  ) throws {
    try requireCodexInactiveAfterKeychainInstallation(fallback)
    do {
      try verifyCodexKeychain(installed, storage: storage)
    } catch {
      try restoreCodexFallback(fallback, storage: storage)
      throw error
    }

    let source = ProviderCredentialSource.codexAuthFile(path: storage.authFileURL.path)
    let observed: Data?
    do {
      observed = try storage.payload(for: source)
    } catch {
      try restoreCodexKeychain(previous, replacing: installed, storage: storage)
      try restoreCodexFallback(fallback, storage: storage)
      throw AccountSwitchError.writeFailed(
        underlying: "Codex's fallback couldn't be verified; the keychain update was rolled back: "
          + error.localizedDescription
      )
    }

    if fallback.quarantineURL != nil {
      guard observed == nil else {
        try discardCodexFallback(fallback)
        try handleChangedCodexFallbackFile(
          observed,
          previousKeychainPayload: previous,
          installedKeychainPayload: installed,
          storage: storage,
          now: now
        )
      }
      try discardCodexFallback(fallback)
    } else if observed != fallback.expectedPayload {
      try handleChangedCodexFallbackFile(
        observed,
        previousKeychainPayload: previous,
        installedKeychainPayload: installed,
        storage: storage,
        now: now
      )
    }
    try verifyCodexKeychain(installed, storage: storage)
  }

  private func requireCodexInactiveAfterKeychainInstallation(
    _ fallback: CodexFallbackTransition
  ) throws {
    do {
      try requireCLIInactive(.codex)
    } catch {
      let activityError = error
      do {
        try discardCodexFallback(fallback)
      } catch {
        throw AccountSwitchError.partialSwitch(
          underlying: "Codex became active after the keychain update, and its prior fallback "
            + "couldn't be removed safely: \(activityError.localizedDescription) "
            + error.localizedDescription
        )
      }
      throw AccountSwitchError.partialSwitch(underlying: activityError.localizedDescription)
    }
  }

  private func verifyCodexKeychain(
    _ expected: Data,
    storage: CodexAuthStorage
  ) throws {
    let observed: Data?
    do {
      observed = try codexKeychainRead(CodexAuthStorage.keychainService, storage.keychainAccount)
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's keychain couldn't be verified after the switch: " + error.localizedDescription
      )
    }
    guard observed == expected else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's keychain changed after Quotari wrote it; the newer value was left untouched."
      )
    }
  }

  private func rejectChangedCodexQuarantine(
    _ observed: Data?,
    transition: CodexFallbackTransition,
    storage: CodexAuthStorage,
    now: Date
  ) throws -> Never {
    var backupError: Error?
    if let observed {
      do {
        try backUp(
          provider: .codex,
          payload: observed,
          origin: .codexAuthFile(path: storage.authFileURL.path),
          now: now
        )
      } catch {
        backupError = error
      }
    }
    try restoreCodexFallback(transition, storage: storage)
    if let backupError {
      throw AccountSwitchError.writeFailed(
        underlying: "Codex's changed fallback couldn't be backed up: " + backupError.localizedDescription
      )
    }
    throw AccountSwitchError.concurrentCredentialChange
  }

  private func restoreCodexFallback(
    _ transition: CodexFallbackTransition,
    storage: CodexAuthStorage
  ) throws {
    guard let quarantineURL = transition.quarantineURL,
          FileManager.default.fileExists(atPath: quarantineURL.path)
    else { return }
    guard !FileManager.default.fileExists(atPath: storage.authFileURL.path) else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex created a new fallback while the prior generation remained quarantined at "
          + quarantineURL.path
      )
    }
    do {
      try FileManager.default.moveItem(at: quarantineURL, to: storage.authFileURL)
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's quarantined fallback couldn't be restored: " + error.localizedDescription
      )
    }
  }

  private func discardCodexFallback(_ transition: CodexFallbackTransition) throws {
    guard let quarantineURL = transition.quarantineURL,
          FileManager.default.fileExists(atPath: quarantineURL.path)
    else { return }
    do {
      try FileManager.default.removeItem(at: quarantineURL)
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's inactive fallback quarantine couldn't be removed: " + error.localizedDescription
      )
    }
  }

  private func handleChangedCodexFallbackFile(
    _ observed: Data?,
    previousKeychainPayload: Data?,
    installedKeychainPayload: Data,
    storage: CodexAuthStorage,
    now: Date
  ) throws -> Never {
    var backupError: Error?
    if let observed {
      do {
        try backUp(
          provider: .codex,
          payload: observed,
          origin: .codexAuthFile(path: storage.authFileURL.path),
          now: now
        )
      } catch {
        backupError = error
      }
    }
    try restoreCodexKeychain(
      previousKeychainPayload,
      replacing: installedKeychainPayload,
      storage: storage
    )
    if let backupError {
      throw AccountSwitchError.writeFailed(
        underlying: "Codex's fallback changed and couldn't be backed up: " + backupError.localizedDescription
      )
    }
    throw AccountSwitchError.writeFailed(
      underlying: "Codex's fallback changed while the keychain update was being verified."
    )
  }

  private func restoreCodexKeychain(
    _ previous: Data?,
    replacing installed: Data,
    storage: CodexAuthStorage
  ) throws {
    do {
      try requireCLIInactive(.codex)
    } catch {
      throw AccountSwitchError.partialSwitch(underlying: error.localizedDescription)
    }
    let current: Data?
    do {
      current = try codexKeychainRead(CodexAuthStorage.keychainService, storage.keychainAccount)
    } catch {
      throw AccountSwitchError.partialSwitch(underlying: error.localizedDescription)
    }
    guard current == installed else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's keychain changed after Quotari wrote it; the newer value was left untouched."
      )
    }

    var operationError: Error?
    do {
      if let previous {
        try codexKeychainWrite(previous, CodexAuthStorage.keychainService, storage.keychainAccount)
      } else {
        try codexKeychainDelete(CodexAuthStorage.keychainService, storage.keychainAccount)
      }
    } catch {
      operationError = error
    }
    let observed: Data?
    do {
      observed = try codexKeychainRead(CodexAuthStorage.keychainService, storage.keychainAccount)
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: operationError?.localizedDescription ?? error.localizedDescription
      )
    }
    guard observed == previous else {
      throw AccountSwitchError.partialSwitch(
        underlying: operationError?.localizedDescription
          ?? "Codex's previous keychain value couldn't be restored."
      )
    }
  }

  private struct CodexFallbackTransition {
    var expectedPayload: Data?
    var quarantineURL: URL?
  }
}
