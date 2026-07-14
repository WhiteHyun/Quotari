import Foundation

extension AccountSwitchService {
  // MARK: - Codex (configured file/keyring/auto backend)

  func switchCodex(registryID: String, now: Date) throws -> ProviderCredentialSource {
    let storage = CodexAuthStorage(
      environment: environment,
      home: home,
      keychainRead: codexKeychainRead
    )
    var current = try readCodexSnapshot(storage)

    // A source or credential generation that changes while backups are being
    // made is re-snapshotted and backed up before the switch. Bounding the
    // loop fails closed if another process keeps rotating the slot. The final
    // write still has the narrow non-atomic interprocess window tracked by
    // PS-144, but no change observed by these CAS-style reads is overwritten.
    for _ in 0 ..< 4 {
      try backUp(provider: .codex, payload: current.payload, origin: current.source, now: now)
      let confirmed = try readCodexSnapshot(storage)
      guard confirmed == current else {
        current = confirmed
        continue
      }
      let prewrite = try readCodexSnapshot(storage)
      guard prewrite == current else {
        current = prewrite
        continue
      }

      // Back up an inactive fallback before materializing the target: that
      // fallback can be a fresher generation of the selected saved account.
      let expectedFallbackFilePayload: Data? = switch current.mode {
      case .keyring:
        try backUpCodexFallbackFile(storage, now: now)
      case .auto where current.source == storage.keychainSource:
        try backUpCodexFallbackFile(storage, now: now)
      case .auto, .file:
        nil
      }
      let afterFallbackBackup = try readCodexSnapshot(storage)
      guard afterFallbackBackup == current else {
        current = afterFallbackBackup
        continue
      }

      // Re-read the target AFTER every backup: capturing a matching login may
      // have refreshed the saved registry row in place.
      let savedPayload = try targetPayload(registryID: registryID)
      let merged: Data
      do {
        merged = try Self.transplantCodex(saved: savedPayload, intoLive: current.payload)
      } catch {
        throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
      }
      return try writeCodex(
        merged,
        replacing: current,
        storage: storage,
        expectedFallbackFilePayload: expectedFallbackFilePayload,
        now: now
      )
    }
    throw AccountSwitchError.slotReadFailed(
      underlying: "Codex credentials kept changing during the account switch."
    )
  }

  private func readCodexSnapshot(_ storage: CodexAuthStorage) throws -> CodexAuthSnapshot {
    do {
      return try storage.snapshot()
    } catch {
      throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
    }
  }

  private func writeCodex(
    _ payload: Data,
    replacing snapshot: CodexAuthSnapshot,
    storage: CodexAuthStorage,
    expectedFallbackFilePayload: Data?,
    now: Date
  ) throws -> ProviderCredentialSource {
    switch snapshot.mode {
    case .file:
      try writeCodexFile(payload, to: storage.authFileURL)
      return .codexAuthFile(path: storage.authFileURL.path)
    case .keyring:
      guard snapshot.payload != nil else {
        throw AccountSwitchError.writeFailed(
          underlying: "Codex must create its keychain item before Quotari can switch it."
        )
      }
      try writeCodexKeychain(payload, replacing: snapshot.payload, storage: storage)
      try removeCodexFallbackFileOrRollBackKeychain(
        storage,
        expectedFilePayload: expectedFallbackFilePayload,
        previousKeychainPayload: snapshot.payload,
        now: now
      )
      return storage.keychainSource
    case .auto:
      if case .codexKeychain = snapshot.source {
        try writeCodexKeychain(payload, replacing: snapshot.payload, storage: storage)
        try removeCodexFallbackFileOrRollBackKeychain(
          storage,
          expectedFilePayload: expectedFallbackFilePayload,
          previousKeychainPayload: snapshot.payload,
          now: now
        )
        return storage.keychainSource
      }
      guard snapshot.keyringState != .unavailable else {
        throw AccountSwitchError.writeFailed(underlying: "Codex's keychain item is unreadable.")
      }
      // Codex must create a genuinely missing item with its own access policy.
      try writeCodexFile(payload, to: storage.authFileURL)
      return .codexAuthFile(path: storage.authFileURL.path)
    }
  }

  private func writeCodexFile(_ payload: Data, to url: URL) throws {
    let prepared: URL
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      prepared = try secureFileWriter.prepare(payload, replacing: url)
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
    defer { secureFileWriter.discard(prepared) }
    do {
      try secureFileWriter.commit(prepared, replacing: url)
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
  }

  private func writeCodexKeychain(
    _ payload: Data,
    replacing previous: Data?,
    storage: CodexAuthStorage
  ) throws {
    do {
      try codexKeychainWrite(payload, CodexAuthStorage.keychainService, storage.keychainAccount)
    } catch {
      let writeError = error
      let observed: Data?
      do {
        observed = try codexKeychainRead(CodexAuthStorage.keychainService, storage.keychainAccount)
      } catch {
        throw AccountSwitchError.partialSwitch(
          underlying: "The Codex keychain write failed and its result couldn't be verified: "
            + error.localizedDescription
        )
      }
      if observed == payload {
        return // the write landed even though the backend reported an error
      }
      guard observed == previous else {
        throw AccountSwitchError.partialSwitch(underlying: writeError.localizedDescription)
      }
      throw AccountSwitchError.writeFailed(underlying: writeError.localizedDescription)
    }
    do {
      let observed = try codexKeychainRead(CodexAuthStorage.keychainService, storage.keychainAccount)
      guard observed == payload else {
        throw AccountSwitchError.partialSwitch(
          underlying: "Codex's keychain item changed while the write was being verified."
        )
      }
    } catch let error as AccountSwitchError {
      throw error
    } catch {
      throw AccountSwitchError.partialSwitch(underlying: error.localizedDescription)
    }
  }

  private func backUpCodexFallbackFile(_ storage: CodexAuthStorage, now: Date) throws -> Data? {
    let source = ProviderCredentialSource.codexAuthFile(path: storage.authFileURL.path)
    let payload: Data?
    do {
      payload = try storage.payload(for: source)
    } catch {
      throw AccountSwitchError.slotReadFailed(underlying: error.localizedDescription)
    }
    try backUp(provider: .codex, payload: payload, origin: source, now: now)
    return payload
  }

  private func removeCodexFallbackFileOrRollBackKeychain(
    _ storage: CodexAuthStorage,
    expectedFilePayload: Data?,
    previousKeychainPayload: Data?,
    now: Date
  ) throws {
    let source = ProviderCredentialSource.codexAuthFile(path: storage.authFileURL.path)
    let observedFilePayload: Data?
    do {
      observedFilePayload = try storage.payload(for: source)
    } catch {
      try restoreCodexKeychain(previousKeychainPayload, storage: storage)
      throw AccountSwitchError.writeFailed(
        underlying: "Codex's fallback file couldn't be verified after the keychain update: "
          + error.localizedDescription
      )
    }

    guard observedFilePayload == expectedFilePayload else {
      var backupError: Error?
      if let observedFilePayload {
        do {
          try backUp(provider: .codex, payload: observedFilePayload, origin: source, now: now)
        } catch {
          backupError = error
        }
      }
      try restoreCodexKeychain(previousKeychainPayload, storage: storage)
      if let backupError {
        throw AccountSwitchError.writeFailed(
          underlying: "Codex's fallback file changed and its new generation couldn't be backed up: "
            + backupError.localizedDescription
        )
      }
      throw AccountSwitchError.writeFailed(
        underlying: "Codex's fallback file changed while the keychain update was being verified."
      )
    }

    guard let observedFilePayload else { return }
    guard CodexAuthStorage.canRemoveFallback(observedFilePayload) else { return }
    do {
      try FileManager.default.removeItem(at: storage.authFileURL)
    } catch {
      try restoreCodexKeychain(previousKeychainPayload, storage: storage)
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
  }

  private func restoreCodexKeychain(
    _ previousPayload: Data?,
    storage: CodexAuthStorage
  ) throws {
    var operationError: Error?
    do {
      if let previousPayload {
        try codexKeychainWrite(
          previousPayload,
          CodexAuthStorage.keychainService,
          storage.keychainAccount
        )
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
    guard observed == previousPayload else {
      throw AccountSwitchError.partialSwitch(
        underlying: operationError?.localizedDescription
          ?? "Codex's previous keychain value couldn't be restored."
      )
    }
  }
}
