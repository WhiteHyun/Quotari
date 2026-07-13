import Foundation

/// A live Claude source whose current access-token generation was verified
/// against the saved account's profile immediately before a switch. The
/// service rechecks the fingerprint on every slot read before it may refresh
/// that saved registry row in place.
public struct KnownLiveClaudeTarget: Equatable, Sendable {
  public var source: ProviderCredentialSource
  public var accessTokenFingerprint: String

  public init(source: ProviderCredentialSource, accessTokenFingerprint: String) {
    self.source = source
    self.accessTokenFingerprint = accessTokenFingerprint
  }
}

/// Switches the account a CLI actually uses: writes a saved (registry)
/// account's credentials into the CLI's own credential slot — the Claude Code
/// keychain item AND `~/.claude/.credentials.json` when present (both, so the
/// CLI's read-precedence can't resurrect the old login), or the effective
/// Codex `auth.json` (`CODEX_HOME` over the default).
///
/// The switch preserves every login it observes before overwriting a slot.
/// Every slot it will overwrite is read (a read *failure* aborts — only a
/// genuine absence proceeds), and each distinct renewable login found is
/// captured into the registry before any write. A login that can't be backed
/// up aborts the switch with the slot untouched; an empty, unidentifiable, or
/// unrenewable slot (nothing durable to lose) proceeds.
/// Right before writing, the slot is re-read: if the CLI rotated it in the
/// meantime, that newer login is backed up too. Only the provider's own
/// credential object is transplanted — every other root key (`mcpOAuth`,
/// `OPENAI_API_KEY`, unknown future keys) survives.
///
/// A residual window remains between the final re-read and the write: the CLI
/// is a separate process and these stores do not offer an interprocess CAS.
/// Callers must ask users to stop active CLI sessions before switching; a CLI
/// rotation inside that window can otherwise be overwritten before Quotari
/// observes the new pair.
public struct AccountSwitchService: Sendable {
  let capturedAccounts: CapturedAccountStore
  let capture: AccountCaptureService
  let environment: [String: String]
  let home: URL
  let keychainRead: @Sendable (String) throws -> Data?
  let keychainWrite: @Sendable (Data, String) throws -> Void
  let secureFileWriter: SecureCredentialFileWriter

  public init(
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    capture: AccountCaptureService? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    keychainRead: (@Sendable (String) throws -> Data?)? = nil,
    keychainWrite: (@Sendable (Data, String) throws -> Void)? = nil,
    setOwnerOnlyPermissions: (@Sendable (URL) throws -> Void)? = nil
  ) {
    self.capturedAccounts = capturedAccounts
    self.capture = capture ?? AccountCaptureService(capturedAccounts: capturedAccounts)
    self.environment = environment
    self.home = home
    // Read the Claude item by service only (no account filter), matching how
    // discovery/capture find it — Claude Code may set an account attribute
    // other than NSUserName(). Throwing, so a read failure still fails closed.
    self.keychainRead = keychainRead ?? { service in try KeychainItemStore.readByService(service) }
    // Write to the same item the service-only read found (reusing its account
    // attribute), so the switch updates rather than duplicates the item.
    self
      .keychainWrite = keychainWrite ??
      { data, service in try KeychainItemStore.writeByService(data, service: service) }
    let setOwnerOnlyPermissions = setOwnerOnlyPermissions ?? { url in
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    secureFileWriter = SecureCredentialFileWriter(
      setOwnerOnlyPermissions: setOwnerOnlyPermissions
    )
  }
}

public extension AccountSwitchService {
  /// Performs the switch and returns the credential source it wrote — the
  /// live slot the CLI now reads (Claude keychain, or the effective Codex
  /// `auth.json`). The caller selects the discovered live row with exactly
  /// this source, so usage/refresh follow the store that was switched rather
  /// than a duplicate slot or the registry copy.
  @discardableResult
  func switchCLI(
    toRegistryAccount id: String,
    now: Date,
    knownLiveTarget: KnownLiveClaudeTarget? = nil
  ) throws -> ProviderCredentialSource {
    switch capturedAccounts.account(id: id)?.provider {
    case .claude:
      return try switchClaude(
        registryID: id,
        now: now,
        knownLiveTarget: knownLiveTarget
      )
    case .codex:
      return try switchCodex(registryID: id, now: now)
    case nil:
      throw AccountSwitchError.accountNotFound
    }
  }
}

private extension AccountSwitchService {
  // MARK: - Claude (keychain + optional credentials file, both overwritten)

  private func switchClaude(
    registryID: String,
    now: Date,
    knownLiveTarget: KnownLiveClaudeTarget?
  ) throws -> ProviderCredentialSource {
    let current = try backedUpClaudeSlots(
      registryID: registryID,
      now: now,
      knownLiveTarget: knownLiveTarget
    )
    let service = current.service
    let fileURL = current.fileURL
    let fileSource = current.fileSource
    let keychainNow = current.keychain
    let fileNow = current.file

    // Re-read the target AFTER backups: a backup may have refreshed the same
    // registry id with a fresher copy of the target account.
    let savedPayload = try targetPayload(registryID: registryID)

    // Write only the stores that already existed, so the switch never leaves
    // an orphaned credential in a store the user wasn't using. If NEITHER
    // exists, create the keychain item (the CLI's canonical store).
    let writeKeychain = keychainNow != nil || fileNow == nil
    let writeFile = fileNow != nil

    // Precompute the merged payloads before mutating either store, so a
    // malformed payload fails before we've half-applied the switch.
    let mergedKeychain: Data?
    let mergedFile: Data?
    do {
      mergedKeychain = writeKeychain ? try Self.transplantClaude(saved: savedPayload, intoLive: keychainNow) : nil
      mergedFile = writeFile ? try Self.transplantClaude(saved: savedPayload, intoLive: fileNow) : nil
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }

    let preparedFile = try prepareCredentialFile(mergedFile, replacing: fileURL)
    defer { secureFileWriter.discard(preparedFile) }

    if let mergedKeychain {
      do {
        try keychainWrite(mergedKeychain, service)
      } catch {
        throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
      }
    }
    if let preparedFile {
      do {
        try secureFileWriter.commit(preparedFile, replacing: fileURL)
      } catch {
        // The file content didn't change — roll the keychain back so the two
        // stores don't disagree (which store the CLI reads is version-
        // dependent). The keychain was only written when it already existed
        // (both-stores case), so there's always a prior value to restore. A
        // rollback that itself fails leaves the stores inconsistent — surface
        // that distinctly (both logins are still backed up).
        if mergedKeychain != nil, let keychainNow {
          do {
            try keychainWrite(keychainNow, service)
          } catch let rollbackError {
            throw AccountSwitchError.partialSwitch(underlying: rollbackError.localizedDescription)
          }
        }
        throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
      }
    }
    discardClaudeLivePendingGrantsAfterSuccessfulSwitch(current.pendingGrants)
    // The CLI reads the keychain first when both exist; that's the store the
    // switched-in account should be selected/refreshed under.
    return writeKeychain ? .claudeKeychain(service: service) : fileSource
  }

  /// Backs up both Claude stores, then re-reads and backs them up once more so
  /// a CLI rotation between the first read and the switch is preserved too.
  private func backedUpClaudeSlots(
    registryID: String,
    now: Date,
    knownLiveTarget: KnownLiveClaudeTarget?
  ) throws -> ClaudeSlots {
    let service = ClaudeCredentialsStore.keychainService
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    let keychainSource = ProviderCredentialSource.claudeKeychain(service: service)
    let fileSource = ProviderCredentialSource.claudeCredentialsFile(path: fileURL.standardizedFileURL.path)
    let sources = [keychainSource, fileSource]
    let context = ClaudeBackupContext(
      registryID: registryID,
      now: now,
      knownLiveTarget: knownLiveTarget
    )

    // Snapshot/decode both source-scoped recovery items before any registry
    // backup. One may contain the only refresh token that survived a failed
    // write, and a matching keychain/file mirror must inherit that generation
    // even when the recovery item belongs to the other physical source.
    let first = try claudeLiveSnapshot(
      sources: sources,
      service: service,
      fileURL: fileURL
    )
    _ = try backUpResolvedClaudeSlots(
      first.resolvedSlots,
      verification: first.slots,
      keychainSource: keychainSource,
      fileSource: fileSource,
      context: context
    )

    let current = try claudeLiveSnapshot(
      sources: sources,
      service: service,
      fileURL: fileURL
    )
    guard current.pendingGrants == first.pendingGrants else {
      throw AccountSwitchError.slotReadFailed(
        underlying: "A pending Claude token grant changed during the account switch."
      )
    }
    _ = try backUpResolvedClaudeSlots(
      current.resolvedSlots,
      verification: current.slots,
      keychainSource: keychainSource,
      fileSource: fileSource,
      context: context
    )
    let pendingGrants = try recordDurableClaudeLivePendingGrantBackups(current.pendingGrants)
    return ClaudeSlots(
      service: service,
      fileURL: fileURL,
      fileSource: fileSource,
      // Resolved payloads are backup-only; switching and rollback use the
      // exact second-read bytes so both live stores stay on one generation.
      keychain: current.slots.keychain,
      file: current.slots.file,
      pendingGrants: pendingGrants
    )
  }

  private func claudeLiveSnapshot(
    sources: [ProviderCredentialSource],
    service: String,
    fileURL: URL
  ) throws -> ClaudeLiveSnapshot {
    let pendingGrants = try loadClaudeLivePendingGrants(sources: sources)
    let slots = try ResolvedClaudeLivePayloads(
      keychain: readKeychain(service),
      file: readFile(fileURL)
    )
    let resolvedSlots = try resolveClaudeLivePendingGrants(
      pendingGrants,
      keychain: slots.keychain,
      file: slots.file
    )
    return ClaudeLiveSnapshot(
      pendingGrants: pendingGrants,
      slots: slots,
      resolvedSlots: resolvedSlots
    )
  }

  private func backUpResolvedClaudeSlots(
    _ slots: ResolvedClaudeLivePayloads,
    verification: ResolvedClaudeLivePayloads,
    keychainSource: ProviderCredentialSource,
    fileSource: ProviderCredentialSource,
    context: ClaudeBackupContext
  ) throws -> ResolvedClaudeLivePayloads {
    // Refresh the explicitly verified row before capturing a matching mirror.
    // Its newly rotated identity then makes the mirror converge on that row
    // instead of creating a duplicate under the refresh-token fingerprint.
    if context.knownLiveTarget?.source == fileSource {
      let file = try backedUpClaudeSlot(
        slots.file,
        verificationPayload: verification.file,
        source: fileSource,
        context: context
      )
      let keychain = try backedUpClaudeSlot(
        slots.keychain,
        verificationPayload: verification.keychain,
        source: keychainSource,
        context: context
      )
      return ResolvedClaudeLivePayloads(keychain: keychain, file: file)
    }
    let keychain = try backedUpClaudeSlot(
      slots.keychain,
      verificationPayload: verification.keychain,
      source: keychainSource,
      context: context
    )
    let file = try backedUpClaudeSlot(
      slots.file,
      verificationPayload: verification.file,
      source: fileSource,
      context: context
    )
    return ResolvedClaudeLivePayloads(keychain: keychain, file: file)
  }

  private func backedUpClaudeSlot(
    _ payload: Data?,
    verificationPayload: Data?,
    source: ProviderCredentialSource,
    context: ClaudeBackupContext
  ) throws -> Data? {
    try backedUpSlot(
      payload,
      origin: source,
      now: context.now,
      refreshingTargetID: verifiedTargetID(
        registryID: context.registryID,
        payload: verificationPayload,
        source: source,
        knownLiveTarget: context.knownLiveTarget
      )
    )
  }

  /// Source equality alone is not identity proof: an external relogin can
  /// reuse the same keychain/file slot after the app verified its profile.
  /// Only the exact verified access-token generation may update the selected
  /// saved row. A mismatch is backed up as its own login instead.
  private func verifiedTargetID(
    registryID: String,
    payload: Data?,
    source: ProviderCredentialSource,
    knownLiveTarget: KnownLiveClaudeTarget?
  ) -> String? {
    guard let knownLiveTarget, knownLiveTarget.source == source,
          let payload,
          let credentials = try? ClaudeCredentialsStore.parse(payload),
          ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
          == knownLiveTarget.accessTokenFingerprint
    else { return nil }
    return registryID
  }

  // MARK: - Codex (single effective slot)

  private func switchCodex(registryID: String, now: Date) throws -> ProviderCredentialSource {
    let url: URL = if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
    } else {
      CodexCredentialsStore.defaultURL(home: home)
    }
    let source = ProviderCredentialSource.codexAuthFile(path: url.standardizedFileURL.path)

    // Honor the same permission policy as capture: refuse to snapshot a
    // group/world-readable token file. Aborting here (rather than backing it
    // up anyway) keeps the switch fail-closed — the slot stays untouched.
    try requireSecureCodexSlot(url)

    let livePayload = try readFile(url)
    try backUp(provider: .codex, payload: livePayload, origin: source, now: now)

    let liveNow = try readFile(url)
    if liveNow != livePayload {
      try backUp(provider: .codex, payload: liveNow, origin: source, now: now)
    }

    // Re-read the target AFTER backups (a backup may have refreshed its id).
    let savedPayload = try targetPayload(registryID: registryID)
    let merged: Data
    do {
      merged = try Self.transplantCodex(saved: savedPayload, intoLive: liveNow)
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
    let preparedFile: URL
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      preparedFile = try secureFileWriter.prepare(merged, replacing: url)
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
    defer { secureFileWriter.discard(preparedFile) }

    do {
      try secureFileWriter.commit(preparedFile, replacing: url)
    } catch {
      throw AccountSwitchError.writeFailed(underlying: error.localizedDescription)
    }
    return source
  }
}
