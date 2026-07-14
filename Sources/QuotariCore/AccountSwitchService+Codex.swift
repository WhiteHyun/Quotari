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
    // write still has a narrow non-atomic interprocess window, but post-write
    // verification preserves any newer generation it observes.
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
    // The process check is an inactivity handshake, not a cooperative lock.
    // Pair it with one last active-store generation read immediately before
    // mutation so a rotation during backup/preparation fails closed.
    try requireCLIInactive(.codex)
    guard try readCodexSnapshot(storage) == snapshot else {
      throw AccountSwitchError.concurrentCredentialChange
    }
    switch snapshot.mode {
    case .file:
      try writeCodexFile(payload, replacing: snapshot.payload, at: storage.authFileURL)
      return .codexAuthFile(path: storage.authFileURL.path)
    case .keyring:
      guard snapshot.payload != nil else {
        throw AccountSwitchError.writeFailed(
          underlying: "Codex must create its keychain item before Quotari can switch it."
        )
      }
      try installCodexKeychain(
        payload,
        replacing: snapshot.payload,
        storage,
        expectedFilePayload: expectedFallbackFilePayload,
        now: now
      )
      return storage.keychainSource
    case .auto:
      if case .codexKeychain = snapshot.source {
        try installCodexKeychain(
          payload,
          replacing: snapshot.payload,
          storage,
          expectedFilePayload: expectedFallbackFilePayload,
          now: now
        )
        return storage.keychainSource
      }
      guard snapshot.keyringState != .unavailable else {
        throw AccountSwitchError.writeFailed(underlying: "Codex's keychain item is unreadable.")
      }
      // Codex must create a genuinely missing item with its own access policy.
      try writeCodexFile(payload, replacing: snapshot.payload, at: storage.authFileURL)
      try verifyCodexAutoFileInstallation(payload, storage: storage)
      return .codexAuthFile(path: storage.authFileURL.path)
    }
  }

  private func writeCodexFile(
    _ payload: Data,
    replacing expected: Data?,
    at url: URL
  ) throws {
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
    try requireCLIInactive(.codex)
    guard try readFile(url) == expected else {
      throw AccountSwitchError.concurrentCredentialChange
    }
    do {
      try secureFileWriter.commit(prepared, replacing: url)
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
    let observed: Data?
    do {
      observed = try readFile(url)
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's auth-file write result couldn't be verified: " + error.localizedDescription
      )
    }
    guard observed == payload else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's auth file changed while Quotari's write was being verified."
      )
    }
  }

  func writeCodexKeychain(
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

  private func verifyCodexAutoFileInstallation(
    _ payload: Data,
    storage: CodexAuthStorage
  ) throws {
    let observed: CodexAuthSnapshot
    do {
      observed = try storage.snapshot()
    } catch {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's active credential store couldn't be verified after the file update: "
          + error.localizedDescription
      )
    }
    let expected = CodexAuthSnapshot(
      mode: .auto,
      source: .codexAuthFile(path: storage.authFileURL.path),
      payload: payload,
      keyringState: .missing
    )
    guard observed == expected else {
      throw AccountSwitchError.partialSwitch(
        underlying: "Codex's active credential store changed after the file update; the newer value was left untouched."
      )
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

}
