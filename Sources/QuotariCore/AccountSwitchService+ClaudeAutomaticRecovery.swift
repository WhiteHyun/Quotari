import Foundation

public struct ClaudeCLIRecovery: Sendable {
  public let registryID: String
  public let source: ProviderCredentialSource
  public let profile: ClaudeProfile
  /// Exact credential scopes replaced by this installation, pointing to the
  /// canonical live scope that discovery will expose afterwards.
  public let credentialTransitions: [String: String]
}

extension AccountSwitchService {
  /// Restores only the account Claude already identifies as its login. A
  /// dashboard selection is never permission to replace a different CLI login.
  /// The caller must drain Quotari's credential writers before entering here.
  public func recoverClaudeCLIIfNeeded(
    profiles: [String: ClaudeProfile],
    now: Date
  ) throws -> ClaudeCLIRecovery? {
    try CLIActivityApprovalContext.$snapshot.withValue(nil) {
      try recoverInactiveClaudeCLI(profiles: profiles, now: now)
    }
  }

  private func recoverInactiveClaudeCLI(
    profiles: [String: ClaudeProfile],
    now: Date
  ) throws -> ClaudeCLIRecovery? {
    guard environment[ClaudeCredentialsStore.tokenEnvKey]?.isEmpty != false else { return nil }
    let saved = try capturedAccounts.registeredAccounts(for: .claude)
    guard !saved.isEmpty else { return nil }
    try requireCLIInactive(.claude)

    let service = ClaudeCredentialsStore.keychainService
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    let keychainSource = ProviderCredentialSource.claudeKeychain(service: service)
    let fileSource = ProviderCredentialSource.claudeCredentialsFile(path: fileURL.standardizedFileURL.path)
    let sources = [keychainSource, fileSource]
    // A pending grant may be newer than either saved or live credentials.
    // Leave its existing recovery transaction in charge until it completes.
    guard try loadClaudeLivePendingGrants(sources: sources).isEmpty else { return nil }
    let previous = try ResolvedClaudeLivePayloads(keychain: readKeychain(service), file: readFile(fileURL))
    let stateURL = ClaudeCodeAccountState.configurationURL(environment: environment, home: home)
    guard let state = try readFile(stateURL),
          let oauthAccount = try ClaudeCodeAccountState.oauthAccount(from: state),
          let target = automaticClaudeRecoveryTarget(saved, oauthAccount: oauthAccount, now: now)
    else { return nil }

    let slots = [(keychainSource, previous.keychain), (fileSource, previous.file)]
    let verifiedProfiles = verifiedClaudeRecoveryProfiles(in: slots, profiles: profiles)
    guard slots.allSatisfy({ _, payload in
      canAutomaticallyRestoreClaudeSlot(payload, target: target.profile, profiles: verifiedProfiles, now: now)
    }) else { return nil }
    guard try capturedAccounts.loadPendingGrantData(id: target.saved.id) == nil else { return nil }

    let writeKeychain = previous.keychain != nil || previous.file == nil
    let recoveredSource = writeKeychain ? keychainSource : fileSource
    let transitions = try claudeRecoveryTransitions(from: slots, to: recoveredSource, payload: target.saved.payload)
    let replacement = try ResolvedClaudeLivePayloads(
      keychain: writeKeychain ? Self.transplantClaude(saved: target.saved.payload, intoLive: previous.keychain) : nil,
      file: previous.file != nil ? Self.transplantClaude(saved: target.saved.payload, intoLive: previous.file) : nil
    )
    // Keep the saved generation stable through installation. The ordinary
    // installer rechecks live slots/processes and rolls back on identity races.
    try CapturedAccountStore.mutationLock.withLock {
      guard capturedAccounts.account(id: target.saved.id) == target.saved,
            try capturedAccounts.loadPendingGrantData(id: target.saved.id) == nil,
            try loadClaudeLivePendingGrants(sources: sources).isEmpty,
            try readFile(stateURL) == state
      else { throw AccountSwitchError.concurrentCredentialChange }
      try installClaudeCredentials(ClaudeCredentialInstallation(
        service: service,
        fileURL: fileURL,
        previous: previous,
        replacement: replacement,
        accountState: ClaudeAccountStateInstallation(url: stateURL, previous: state, replacement: state)
      ))
    }
    return ClaudeCLIRecovery(
      registryID: target.saved.id,
      source: recoveredSource,
      profile: target.profile,
      credentialTransitions: transitions
    )
  }

  private func automaticClaudeRecoveryTarget(
    _ saved: [CapturedAccount],
    oauthAccount: Data,
    now: Date
  ) -> (saved: CapturedAccount, profile: ClaudeProfile)? {
    guard let fields = try? JSONSerialization.jsonObject(with: oauthAccount) as? [String: Any] else { return nil }
    let terminalIdentity = ClaudeAccountIdentity(
      accountID: fields["accountUuid"] as? String,
      organizationID: fields["organizationUuid"] as? String
    )
    guard terminalIdentity.isStrong else { return nil }
    let matches = saved.filter { account in
      guard let identity = account.claudeAccountIdentity, identity.isStrong else { return false }
      return identity.identifiesSameAccount(as: terminalIdentity)
    }
    guard matches.count == 1, let account = matches.first,
          let identity = account.claudeAccountIdentity,
          let credentials = try? ClaudeCredentialsStore.parse(account.payload),
          credentials.refreshToken?.isEmpty == false,
          credentials.expiresAt != nil,
          !credentials.isExpired(now: now)
    else { return nil }
    return (account, ClaudeProfile(
      accountID: identity.accountID,
      email: identity.email,
      organizationID: identity.organizationID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
    ))
  }

  private func verifiedClaudeRecoveryProfiles(
    in slots: [(ProviderCredentialSource, Data?)],
    profiles: [String: ClaudeProfile]
  ) -> [ClaudeProfile] {
    slots.compactMap { source, payload in
      guard let payload, let credentials = try? ClaudeCredentialsStore.parse(payload),
            let profile = profiles[ProviderAccount.id(provider: .claude, source: source)],
            profile.fingerprint == ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
      else { return nil }
      return profile
    }
  }

  private func canAutomaticallyRestoreClaudeSlot(
    _ payload: Data?,
    target: ClaudeProfile,
    profiles: [ClaudeProfile],
    now: Date
  ) -> Bool {
    guard let payload else { return true }
    if let credentials = try? ClaudeCredentialsStore.parse(payload) {
      // Terminal metadata can lag an external login. Require profile evidence
      // bound to the actual token before replacing any nonempty credential.
      // Discovery hides identical mirrors, so they share the canonical slot's
      // proof only when their access-token fingerprints match exactly.
      let fingerprint = ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
      let matchingProfiles = profiles.filter { $0.fingerprint == fingerprint }
      return credentials.isExpired(now: now) && !matchingProfiles.isEmpty
        && matchingProfiles.allSatisfy { $0.stronglyIdentifiesSameAccount(as: target) }
    }
    // A recognized empty OAuth slot is recoverable; unknown/corrupt data is
    // not evidence of logout or permission to overwrite another credential.
    guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any]
    else { return false }
    return ["accessToken", "refreshToken"].allSatisfy { key in
      oauth[key] == nil || (oauth[key] as? String)?.isEmpty == true
    }
  }

  private func claudeRecoveryTransitions(
    from slots: [(ProviderCredentialSource, Data?)],
    to source: ProviderCredentialSource,
    payload: Data
  ) throws -> [String: String] {
    let installed = try ClaudeCredentialsStore.parse(payload)
    let target = ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: nil,
      credentialSource: source, credentialIdentity: installed.accessToken
    )
    return slots.reduce(into: [:]) { transitions, slot in
      guard let payload = slot.1, let credentials = try? ClaudeCredentialsStore.parse(payload) else { return }
      let previous = ProviderAccount(
        provider: .claude, displayName: "Claude Code", detail: nil,
        credentialSource: slot.0, credentialIdentity: credentials.accessToken
      )
      transitions[previous.credentialScopeID] = target.credentialScopeID
    }
  }
}
