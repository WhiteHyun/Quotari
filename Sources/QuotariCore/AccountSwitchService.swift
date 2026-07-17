import Foundation

/// Switches the account a CLI actually uses: writes a saved (registry)
/// account's credentials into the CLI's own credential slot — the Claude Code
/// keychain item, `~/.claude/.credentials.json` when present, AND the matching
/// `~/.claude.json.oauthAccount` identity (so new terminals label the switched
/// credential correctly), or the effective
/// Codex's configured file/keyring/auto credential backend (scoped by the
/// effective `CODEX_HOME`).
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
/// Production callers pair repeated generation reads with an active-process
/// check. The CLI remains a separate process and these stores do not offer an
/// interprocess CAS, so users must still stop active sessions. Post-write
/// verification preserves any newer generation it observes. If only Claude's
/// lower-precedence file changes, Quotari rolls back its matching keychain
/// write so a retry can back up both physical stores safely.
public struct AccountSwitchService: Sendable {
  let capturedAccounts: CapturedAccountStore
  let capture: AccountCaptureService
  let environment: [String: String]
  let home: URL
  let keychainRead: @Sendable (String) throws -> Data?
  let keychainWrite: @Sendable (Data, String) throws -> Void
  let keychainDelete: @Sendable (String) throws -> Void
  let codexKeychainRead: @Sendable (String, String) throws -> Data?
  let codexKeychainWrite: @Sendable (Data, String, String) throws -> Void
  let codexKeychainDelete: @Sendable (String, String) throws -> Void
  let activeCLIProcesses: @Sendable (UsageProvider) throws -> [String]
  let credentialFileRead: @Sendable (URL) throws -> Data?
  let secureFileWriter: SecureCredentialFileWriter

  public init(
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    capture: AccountCaptureService? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    keychainRead: (@Sendable (String) throws -> Data?)? = nil,
    keychainWrite: (@Sendable (Data, String) throws -> Void)? = nil,
    keychainDelete: (@Sendable (String) throws -> Void)? = nil,
    codexKeychainRead: (@Sendable (String, String) throws -> Data?)? = nil,
    codexKeychainWrite: (@Sendable (Data, String, String) throws -> Void)? = nil,
    codexKeychainDelete: (@Sendable (String, String) throws -> Void)? = nil,
    activeCLIProcesses: @escaping @Sendable (UsageProvider) throws -> [String] = { _ in [] },
    fileRead: (@Sendable (URL) throws -> Data?)? = nil,
    setOwnerOnlyPermissions: (@Sendable (URL) throws -> Void)? = nil
  ) {
    let resolvedCodexKeychainRead = codexKeychainRead ?? { service, account in
      try KeychainItemStore(account: account).read(service: service)
    }
    self.capturedAccounts = capturedAccounts
    self.capture = capture ?? AccountCaptureService(
      capturedAccounts: capturedAccounts,
      codexKeychainRead: { service, account in
        try? resolvedCodexKeychainRead(service, account)
      }
    )
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
    self.keychainDelete = keychainDelete ?? { service in
      try KeychainItemStore.deleteByService(service)
    }
    self.codexKeychainRead = resolvedCodexKeychainRead
    self.codexKeychainWrite = codexKeychainWrite ?? { data, service, account in
      try KeychainItemStore(account: account).write(data, service: service)
    }
    self.codexKeychainDelete = codexKeychainDelete ?? { service, account in
      try KeychainItemStore(account: account).delete(service: service)
    }
    self.activeCLIProcesses = activeCLIProcesses
    credentialFileRead = fileRead ?? { url in
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try Data(contentsOf: url)
    }
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
  /// live slot the CLI now reads (Claude keychain, or Codex's resolved file or
  /// keychain backend). The caller selects the discovered live row with exactly
  /// this source, so usage/refresh follow the store that was switched rather
  /// than a duplicate slot or the registry copy.
  @discardableResult
  func switchCLI(
    toRegistryAccount id: String,
    now: Date,
    knownLiveTarget: KnownLiveClaudeTarget? = nil,
    targetClaudeProfile: ClaudeProfile? = nil,
    verifiedLiveClaudeIdentity: VerifiedLiveClaudeIdentity? = nil
  ) throws -> ProviderCredentialSource {
    let provider = capturedAccounts.account(id: id)?.provider
    if let provider {
      try requireCLIInactive(provider)
    }
    switch provider {
    case .claude:
      return try switchClaude(
        registryID: id,
        now: now,
        knownLiveTarget: knownLiveTarget,
        targetProfile: targetClaudeProfile,
        verifiedLiveIdentity: verifiedLiveClaudeIdentity
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
    knownLiveTarget: KnownLiveClaudeTarget?,
    targetProfile: ClaudeProfile?,
    verifiedLiveIdentity: VerifiedLiveClaudeIdentity?
  ) throws -> ProviderCredentialSource {
    let current = try backedUpClaudeSlots(
      registryID: registryID,
      now: now,
      knownLiveTarget: knownLiveTarget,
      verifiedLiveIdentity: verifiedLiveIdentity
    )
    let service = current.service
    let fileURL = current.fileURL
    let fileSource = current.fileSource
    let keychainNow = current.keychain
    let fileNow = current.file

    // Re-read the target AFTER backups: a backup may have refreshed the same
    // registry id with a fresher copy of the target account.
    let savedPayload = try targetPayload(registryID: registryID)
    let accountState = try claudeAccountStateInstallation(
      registryID: registryID,
      targetProfile: targetProfile
    )

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

    try installClaudeCredentials(ClaudeCredentialInstallation(
      service: service,
      fileURL: fileURL,
      previous: ResolvedClaudeLivePayloads(keychain: keychainNow, file: fileNow),
      replacement: ResolvedClaudeLivePayloads(keychain: mergedKeychain, file: mergedFile),
      accountState: accountState
    ))
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
    knownLiveTarget: KnownLiveClaudeTarget?,
    verifiedLiveIdentity: VerifiedLiveClaudeIdentity?
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

    let current = try stableClaudeLiveSnapshot(
      sources: sources,
      service: service,
      fileURL: fileURL,
      expectedPendingGrants: first.pendingGrants
    )
    let currentOAuthAccount = try stableClaudeOAuthAccount(
      matching: current.slots,
      service: service,
      fileURL: fileURL,
      verifiedLiveIdentity: verifiedLiveIdentity
    )
    _ = try backUpResolvedClaudeSlots(
      current.resolvedSlots,
      verification: current.slots,
      keychainSource: keychainSource,
      fileSource: fileSource,
      context: context,
      claudeOAuthAccount: currentOAuthAccount
    )
    return try ClaudeSlots(
      service: service,
      fileURL: fileURL,
      fileSource: fileSource,
      // Resolved payloads are backup-only; switching and rollback use the
      // exact second-read bytes so both live stores stay on one generation.
      keychain: current.slots.keychain,
      file: current.slots.file,
      pendingGrants: recordDurableClaudeLivePendingGrantBackups(current.pendingGrants)
    )
  }

  private func stableClaudeLiveSnapshot(
    sources: [ProviderCredentialSource],
    service: String,
    fileURL: URL,
    expectedPendingGrants: [ClaudeLivePendingGrant]
  ) throws -> ClaudeLiveSnapshot {
    let current = try claudeLiveSnapshot(
      sources: sources,
      service: service,
      fileURL: fileURL
    )
    guard current.pendingGrants == expectedPendingGrants else {
      throw AccountSwitchError.slotReadFailed(
        underlying: "A pending Claude token grant changed during the account switch."
      )
    }
    return current
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
    context: ClaudeBackupContext,
    claudeOAuthAccount: Data? = nil
  ) throws -> ResolvedClaudeLivePayloads {
    let keychainIsCanonical = verification.keychain.flatMap {
      try? ClaudeCredentialsStore.parse($0)
    } != nil
    // Refresh the explicitly verified row before capturing a matching mirror.
    // Its newly rotated identity then makes the mirror converge on that row
    // instead of creating a duplicate under the refresh-token fingerprint.
    if context.knownLiveTarget?.source == fileSource {
      let file = try backedUpClaudeSlot(
        slots.file,
        verificationPayload: verification.file,
        source: fileSource,
        context: context,
        claudeOAuthAccount: keychainIsCanonical ? nil : claudeOAuthAccount
      )
      let keychain = try backedUpClaudeSlot(
        slots.keychain,
        verificationPayload: verification.keychain,
        source: keychainSource,
        context: context,
        claudeOAuthAccount: keychainIsCanonical ? claudeOAuthAccount : nil
      )
      return ResolvedClaudeLivePayloads(keychain: keychain, file: file)
    }
    let keychain = try backedUpClaudeSlot(
      slots.keychain,
      verificationPayload: verification.keychain,
      source: keychainSource,
      context: context,
      claudeOAuthAccount: keychainIsCanonical ? claudeOAuthAccount : nil
    )
    let file = try backedUpClaudeSlot(
      slots.file,
      verificationPayload: verification.file,
      source: fileSource,
      context: context,
      claudeOAuthAccount: keychainIsCanonical ? nil : claudeOAuthAccount
    )
    return ResolvedClaudeLivePayloads(keychain: keychain, file: file)
  }

  private func backedUpClaudeSlot(
    _ payload: Data?,
    verificationPayload: Data?,
    source: ProviderCredentialSource,
    context: ClaudeBackupContext,
    claudeOAuthAccount: Data? = nil
  ) throws -> Data? {
    let refreshingTargetID = verifiedTargetID(
      registryID: context.registryID,
      payload: verificationPayload,
      source: source,
      knownLiveTarget: context.knownLiveTarget
    )
    return try backedUpSlot(
      payload,
      origin: source,
      now: context.now,
      refreshingTargetID: refreshingTargetID,
      // A known target proves the credential generation, not that the
      // terminal state beside it is current. Keep its trusted saved identity.
      claudeOAuthAccount: refreshingTargetID == nil ? claudeOAuthAccount : nil
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
}
