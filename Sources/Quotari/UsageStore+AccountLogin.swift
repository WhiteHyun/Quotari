import Foundation
import QuotariCore

enum AccountLoginPhase: Equatable {
  case preservingCurrentAccount
  case waitingForBrowser
  case waitingForAuthenticationCode
  case completingLogin
  case savingAccount
  case restoringPreviousAccount

  var title: String {
    switch self {
    case .preservingCurrentAccount: L10n.string("Saving current CLI account…")
    case .waitingForBrowser: L10n.string("Waiting for browser login…")
    case .waitingForAuthenticationCode: L10n.string("Authentication code required")
    case .completingLogin: L10n.string("Completing sign-in…")
    case .savingAccount: L10n.string("Adding the new account…")
    case .restoringPreviousAccount: L10n.string("Restoring the previous CLI account…")
    }
  }

  var detail: String? {
    switch self {
    case .preservingCurrentAccount:
      L10n.string("Quotari is preserving the current renewable credential before adding another account.")
    case .waitingForBrowser:
      L10n.string("Finish signing in with a different account in the browser. Keep this window open.")
    case .waitingForAuthenticationCode:
      L10n.string("Paste the authentication code shown in the browser to continue the Claude Code login.")
    case .completingLogin:
      L10n.string("Claude Code accepted the browser sign-in and Quotari is waiting for it to finish.")
    case .savingAccount:
      L10n.string("The new renewable credential is being saved to Quotari and linked to the live CLI account.")
    case .restoringPreviousAccount:
      L10n.string("Login did not complete, so Quotari is putting the preserved account back into the CLI slot.")
    }
  }

  var allowsCancellation: Bool {
    switch self {
    case .waitingForBrowser, .waitingForAuthenticationCode, .completingLogin: true
    case .preservingCurrentAccount, .savingAccount, .restoringPreviousAccount: false
    }
  }
}

extension UsageStore {
  func startAddingAccount(for provider: UsageProvider) {
    guard accountLoginTasks[provider] == nil else { return }
    accountLoginTasks[provider] = Task { [weak self] in
      guard let self else { return }
      await addAccount(for: provider)
      accountLoginTasks[provider] = nil
    }
  }

  func cancelAccountLogin(for provider: UsageProvider) {
    accountLoginTasks[provider]?.cancel()
  }

  func canAddAccount(for provider: UsageProvider) -> Bool {
    accountLogin.supports(provider: provider)
  }

  func addAccountUnavailableReason(for provider: UsageProvider) -> String? {
    accountLogin.unavailableReason(provider: provider)
  }

  func addAccount(for provider: UsageProvider) async {
    guard addingAccountProviders.isEmpty else {
      accountLoginErrors[provider] = L10n.string(
        "Finish the account login already in progress before starting another one."
      )
      return
    }
    guard !isSwitching else {
      accountLoginErrors[provider] = L10n.string(
        "Finish the account switch already in progress before starting a new login."
      )
      return
    }

    addingAccountProviders.insert(provider)
    accountLoginPhases[provider] = .preservingCurrentAccount
    accountLoginErrors[provider] = nil
    accountLoginOutputs[provider] = nil
    accountLoginOutputSanitizers[provider] = AccountLoginOutputSanitizer()
    var ownsCredentialGate = false
    defer {
      endAccountLoginCredentialGate(ifOwnedBy: &ownsCredentialGate)
      addingAccountProviders.remove(provider)
      accountLoginPhases[provider] = nil
      accountLoginOutputSanitizers[provider] = nil
    }

    let previousClaudeLogin: PreservedClaudeLogin?
    do {
      previousClaudeLogin = try await prepareAccountLogin(for: provider)
    } catch {
      accountLoginErrors[provider] = error.localizedDescription
      return
    }
    do {
      ownsCredentialGate = try await acquireAccountLoginCredentialGate(for: provider)
    } catch {
      accountLoginErrors[provider] = error.localizedDescription
      return
    }
    let registryBaseline: AccountLoginRegistryBaseline?
    do {
      registryBaseline = try await accountRegistryBaseline(for: provider)
    } catch {
      accountLoginErrors[provider] = AddedAccountImportError.registrySnapshotFailed.localizedDescription
      return
    }

    await runPreparedAccountLogin(
      for: provider,
      previousClaudeLogin: previousClaudeLogin,
      registryBaseline: registryBaseline,
      ownsCredentialGate: &ownsCredentialGate
    )
  }

  private func runPreparedAccountLogin(
    for provider: UsageProvider,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline?,
    ownsCredentialGate: inout Bool
  ) async {
    do {
      let result = try await performAccountLogin(
        for: provider,
        previousClaudeLogin: previousClaudeLogin,
        registryBaseline: registryBaseline
      )
      accountLoginPhases[provider] = .savingAccount
      let captured = try await importAccountLoginResult(
        result,
        previousClaudeLogin: previousClaudeLogin,
        registryBaseline: registryBaseline
      )
      await finishAccountLogin(captured, for: provider)
      if provider == .claude {
        endAccountLoginCredentialGate(ifOwnedBy: &ownsCredentialGate)
      }
      enqueuePostCredentialRefresh(for: provider)
    } catch is CancellationError {
      let restorationError = await restoreClaudeAccountIfNeeded(
        preservingDashboardSelection: persistableSelections()[provider],
        registryBaseline: registryBaseline
      )
      accountLoginErrors[provider] = combinedLoginError(
        L10n.string("Account login was cancelled."),
        restorationError: restorationError
      )
    } catch {
      let restorationError = await restoreClaudeAccountIfNeeded(
        preservingDashboardSelection: persistableSelections()[provider],
        registryBaseline: registryBaseline
      )
      accountLoginErrors[provider] = combinedLoginError(
        error.localizedDescription,
        restorationError: restorationError
      )
    }
  }

  private func endAccountLoginCredentialGate(ifOwnedBy ownsCredentialGate: inout Bool) {
    guard ownsCredentialGate else { return }
    ownsCredentialGate = false
    isSwitching = false
    startQueuedAccountRediscoveryIfNeeded()
  }

  private func acquireAccountLoginCredentialGate(for provider: UsageProvider) async throws -> Bool {
    guard provider == .claude else { return false }
    // Claude browser login replaces the shared live credential. Reuse the
    // switch gate so timer and manual refreshes cannot rotate that slot
    // between preservation, identity verification, and registry import.
    guard !isSwitching else {
      throw AddedAccountImportError.accountSwitchInProgress
    }
    isSwitching = true
    await drainCredentialActivityBeforeAccountLogin(for: provider)
    return true
  }

  private func drainCredentialActivityBeforeAccountLogin(for provider: UsageProvider) async {
    await inFlightRefresh?.value
    await inFlightAccountReload?.value
    _ = await providerFetchTasks[provider]?.task.value
    _ = await selectionProviderFetchTasks[provider]?.task.value
    _ = await accountUsageRefreshTasks[provider]?.task.value
    await selectionRefreshTasks[provider]?.value
  }

  private func prepareAccountLogin(for provider: UsageProvider) async throws -> PreservedClaudeLogin? {
    // The scan is the preservation boundary: every renewable login already in
    // a live CLI slot must be managed before a second login is allowed to open.
    await reloadAccounts(preserving: provider)
    guard captureErrors[provider] == nil else {
      throw AddedAccountImportError.preservationFailed
    }
    guard provider == .claude else { return nil }
    let liveAccount = liveClaudeCredentialSlotAccount()
    let savedAccount = liveAccount.flatMap { capturedEquivalents[$0.id] }
    if liveAccount != nil, savedAccount == nil {
      throw AddedAccountImportError.savedCopyUnverified
    }
    guard let savedAccount else { return nil }
    let profile: ClaudeProfile
    do {
      profile = try await resolvedClaudeLoginProfile(for: savedAccount)
    } catch {
      throw AddedAccountImportError.savedIdentityUnverified
    }
    return PreservedClaudeLogin(account: savedAccount, profile: profile)
  }

  private func importAccountLoginResult(
    _ result: AccountLoginResult,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline?
  ) async throws -> CapturedAccount {
    let verifiedClaudeProfile: ClaudeProfile?
    let claudeOAuthAccount: Data?
    if result.provider == .claude {
      guard let credentials = try? ClaudeCredentialsStore.parse(result.payload) else {
        throw AddedAccountImportError.notRenewable
      }
      let profile = try await profileFetcher.fetchProfile(accessToken: credentials.accessToken)
      guard profile.hasStableAccountIdentity else {
        throw AddedAccountImportError.identityVerificationFailed
      }
      let credentialFingerprint = ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
      verifiedClaudeProfile = profile.verified(for: credentialFingerprint)
      claudeOAuthAccount = resolvedClaudeOAuthAccount(
        candidate: result.claudeOAuthAccount,
        profile: profile
      )
      let captured: CapturedAccount = if let saved = try await uniquelyMatchingSavedClaudeAccount(
        for: profile,
        previousClaudeLogin: previousClaudeLogin,
        registryBaseline: registryBaseline
      ) {
        try await refreshReauthenticatedClaudeAccount(
          saved,
          payload: result.payload,
          profile: verifiedClaudeProfile,
          claudeOAuthAccount: claudeOAuthAccount
        )
      } else {
        try await captureAccountLoginResult(
          result,
          verifiedClaudeProfile: verifiedClaudeProfile,
          claudeOAuthAccount: claudeOAuthAccount
        )
      }
      try await synchronizeClaudeLoginState(
        captured,
        source: result.origin,
        credentialFingerprint: credentialFingerprint,
        profile: verifiedClaudeProfile
      )
      return captured
    } else {
      verifiedClaudeProfile = nil
      claudeOAuthAccount = nil
    }

    return try await captureAccountLoginResult(
      result,
      verifiedClaudeProfile: verifiedClaudeProfile,
      claudeOAuthAccount: claudeOAuthAccount
    )
  }

  func uniquelyMatchingSavedClaudeAccount(
    for profile: ClaudeProfile,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline? = nil
  ) async throws -> ProviderAccount? {
    var candidates: [String: ProviderAccount] = [:]
    if let previousClaudeLogin {
      candidates[previousClaudeLogin.account.id] = previousClaudeLogin.account
    }
    for account in accounts[.claude] ?? [] where account.credentialSource.isCaptured {
      candidates[account.id] = account
    }
    for account in capturedEquivalents.values where account.provider == .claude {
      candidates[account.id] = account
    }
    for account in registryBaseline?.registeredProviderAccounts ?? [] where account.provider == .claude {
      candidates[account.id] = account
    }

    var matches: [ProviderAccount] = []
    for candidate in candidates.values {
      let savedProfile: ClaudeProfile
      if candidate.id == previousClaudeLogin?.account.id, let previousClaudeLogin {
        savedProfile = previousClaudeLogin.profile
      } else {
        do {
          savedProfile = try await resolvedClaudeLoginProfile(for: candidate)
        } catch {
          throw AddedAccountImportError.savedRegistryIdentityUnverified
        }
      }
      if savedProfile.identifiesSameAccount(as: profile) {
        matches.append(candidate)
      }
    }
    guard matches.count <= 1 else {
      throw AddedAccountImportError.ambiguousSavedIdentity
    }
    return matches.first
  }

  func refreshReauthenticatedClaudeAccount(
    _ saved: ProviderAccount,
    payload: Data,
    profile: ClaudeProfile?,
    claudeOAuthAccount: Data? = nil,
    requiresNewerGenerationEvidence: Bool = false
  ) async throws -> CapturedAccount {
    guard case let .quotariRegistry(id) = saved.credentialSource else {
      throw AddedAccountImportError.savedCopyUnverified
    }
    let capture = accountCapture
    let captured = try await Task.detached {
      try capture.refreshCapturedAccount(
        id: id,
        provider: .claude,
        payload: payload,
        claudeOAuthAccount: claudeOAuthAccount,
        requiresNewerGenerationEvidence: requiresNewerGenerationEvidence
      )
    }.value
    if let profile {
      storeClaudeLoginProfile(profile, for: captured)
    }
    return captured
  }

  func storeClaudeLoginProfile(_ profile: ClaudeProfile, for captured: CapturedAccount) {
    storeClaudeLoginProfile(profile, accountID: captured.providerAccount.id)
  }

  private func storeClaudeLoginProfile(_ profile: ClaudeProfile, accountID: String) {
    claudeProfiles[accountID] = profile
    profileFetchAttempts[accountID] = profile.fingerprint
    emptyClaudeProfileFingerprints[accountID] = nil
    try? profileStore.save(claudeProfiles)
  }

  private func finishAccountLogin(_ captured: CapturedAccount, for provider: UsageProvider) async {
    if isSwitching {
      await reloadAccountsDuringSwitch()
    } else {
      await reloadAccounts()
    }
    let saved = captured.providerAccount
    let visibleAccount = accounts[provider]?.first(where: { account in
      capturedEquivalents[account.id]?.id == saved.id
    }) ?? accounts[provider]?.first(where: { $0.id == saved.id }) ?? saved
    selectAccount(visibleAccount, for: provider)
    includeAccountInAutomaticMonitoring(visibleAccount)
    accountLoginErrors[provider] = nil
    accountLoginOutputs[provider] = nil
  }

  func resolvedClaudeLoginProfile(for saved: ProviderAccount) async throws -> ClaudeProfile {
    let loader = claudeCredentialLoader
    guard let credentials = await Task.detached(operation: {
      loader(saved.credentialSource)
    }).value else {
      throw AddedAccountImportError.savedIdentityUnverified
    }
    let fingerprint = ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
    if let cached = claudeProfiles[saved.id],
       cached.hasStableAccountIdentity,
       cached.fingerprint == fingerprint {
      return cached
    }
    let fetched = try await profileFetcher.fetchProfile(accessToken: credentials.accessToken)
    guard fetched.hasStableAccountIdentity,
          let current = await Task.detached(operation: {
            loader(saved.credentialSource)
          }).value,
          ProviderCredentialIdentity.fingerprint(of: current.accessToken) == fingerprint
    else { throw AddedAccountImportError.savedIdentityUnverified }
    let verified = fetched.verified(for: fingerprint)
    storeClaudeLoginProfile(verified, accountID: saved.id)
    return verified
  }
}
