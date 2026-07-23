import Foundation
import QuotariCore

// MARK: - Saving accounts into the Quotari registry

extension UsageStore {
  static let activeAccountRemovalMessage =
    L10n.string(
      "This account is still present in a CLI credential slot. Switch to another account or sign out before removing it."
    )

  func removeCapturedAccount(_ account: ProviderAccount) async {
    guard case let .quotariRegistry(id) = account.credentialSource else { return }
    // Removal is a policy decision about the live CLI state, not the last
    // picker snapshot. Join a fresh coordinated discovery first so an account
    // switched into a CLI slot while Quotari stayed active cannot be deleted.
    await reloadAccounts()
    let liveEquivalent = await accountDiscovery.liveAccount(
      equivalentTo: account,
      among: accounts[account.provider] ?? []
    )
    let isKnownLive = capturedEquivalents.values.contains(where: { $0.id == account.id })
      || liveEquivalent != nil
    let unresolvedClaudeLiveMayMatch = isKnownLive ? false : await claudeLiveIdentityBlocksRemoval(of: account)
    if isKnownLive || unresolvedClaudeLiveMayMatch {
      captureErrors[account.provider] = Self.activeAccountRemovalMessage
      return
    }
    let capture = accountCapture
    do {
      try await Task.detached { try capture.remove(id: id) }.value
      captureErrors[account.provider] = nil
      if selectedAccounts[account.provider]?.id == account.id {
        selectAccount(nil, for: account.provider)
      } else if reconciledSelectionOrigins[account.provider]?.id == account.id {
        // The removed copy was the selection's logical origin: the selection
        // stays on the live login, now in its own right.
        selectAccount(selectedAccounts[account.provider], for: account.provider, standingInFor: nil)
      }
      await reloadAccounts()
    } catch {
      captureErrors[account.provider] = error.localizedDescription
    }
  }

  /// Removes the hidden saved copy of a live login — its registry row is
  /// suppressed while the identity is live. Product policy keeps every scanned
  /// live login managed, so removal is blocked until its CLI slot is switched
  /// to another account or logged out.
  func removeCapturedCopy(of account: ProviderAccount) async {
    captureErrors[account.provider] = Self.activeAccountRemovalMessage
  }

  /// Claude refresh-token fingerprints cannot identify an unrenewable live
  /// slot: the saved row hashes its refresh token while the live row falls back
  /// to its access token. Only verified current profiles can prove such a row
  /// belongs to another account; unresolved identity therefore fails closed so
  /// removal never deletes the only renewable copy of a login still in a CLI.
  private func claudeLiveIdentityBlocksRemoval(of saved: ProviderAccount) async -> Bool {
    guard saved.provider == .claude else { return false }
    let liveAccounts = (accounts[.claude] ?? []).filter { account in
      switch account.credentialSource {
      case .claudeKeychain, .claudeCredentialsFile:
        true
      case .codexAuthFile, .codexKeychain, .claudeEnvironment, .quotariRegistry:
        false
      }
    }
    guard !liveAccounts.isEmpty else { return false }
    guard let savedProfile = await currentVerifiedClaudeProfile(for: saved) else { return true }
    for live in liveAccounts {
      guard let liveProfile = await currentVerifiedClaudeProfile(for: live) else { return true }
      if savedProfile.identifiesSameAccount(as: liveProfile) {
        return true
      }
    }
    return false
  }

  private func currentVerifiedClaudeProfile(for account: ProviderAccount) async -> ClaudeProfile? {
    guard let profile = claudeProfiles[account.id],
          profile.hasStableAccountIdentity,
          let expectedFingerprint = profile.fingerprint
    else { return nil }
    let loader = claudeCredentialLoader
    let credentials = await Task.detached {
      loader(account.credentialSource)
    }.value
    guard let credentials,
          ProviderCredentialIdentity.fingerprint(of: credentials.accessToken) == expectedFingerprint
    else { return nil }
    return profile
  }

  /// Makes the saved account the CLI's actual login: its credentials are
  /// written into the CLI's own slot (the previous login Quotari observes is
  /// captured first), then discovery re-runs — the
  /// switched-in account becomes the live login with the saved row hidden —
  /// and the selection lands on it, anchored to the saved account.
  func switchCLIAccount(to account: ProviderAccount) async {
    guard case let .quotariRegistry(id) = account.credentialSource else { return }
    let provider = account.provider
    guard !isSwitching else {
      captureErrors[provider] = L10n.string("Another account switch is already in progress.")
      return
    }
    // Close the gate FIRST so no new fetch can start while we drain the
    // in-flight ones — otherwise a timer/UI/popover refresh begun during the
    // awaits below would rotate the slot after we'd moved past it. Every
    // credential-touching entry point (beginRefresh, refresh(provider:),
    // refreshAccountUsage) checks this flag.
    isSwitching = true
    var shouldRefresh = false
    defer {
      isSwitching = false
      startQueuedAccountRediscoveryIfNeeded()
      if shouldRefresh {
        // A selection refresh created during reload can observe the closed
        // gate and exit. Replace it after opening the gate so every successful
        // switch performs exactly one serialized fetch of the live slot.
        enqueueSelectionRefresh(for: provider)
      }
    }
    // Drain whatever was already running when the gate closed.
    await inFlightRefresh?.value
    await inFlightAccountReload?.value
    _ = await accountUsageRefreshTasks[provider]?.task.value
    await selectionRefreshTasks[provider]?.value
    let switcher = accountSwitch
    let knownLiveTarget = knownLiveTarget(for: account)
    let verifiedLiveIdentity = verifiedCanonicalLiveClaudeIdentity()
    let now = Date()
    do {
      var targetClaudeProfile = provider == .claude ? verifiedClaudeProfile(for: account) : nil
      if provider == .claude, targetClaudeProfile == nil {
        // Legacy rows may not have an exact oauthAccount snapshot yet. Use a
        // freshly verified profile when available, but preserve the existing
        // token-switch behavior during a transient profile endpoint failure.
        targetClaudeProfile = try? await resolvedClaudeLoginProfile(for: account)
      }
      // The write runs detached (off the main actor), and `isSwitching`
      // suppresses Quotari refreshes for the window. The switch service also
      // checks separate CLI processes; the confirmation explains its residual
      // non-cooperative launch window.
      let writtenSource = try await Task.detached {
        try switcher.switchCLI(
          toRegistryAccount: id,
          now: now,
          knownLiveTarget: knownLiveTarget,
          targetClaudeProfile: targetClaudeProfile,
          verifiedLiveClaudeIdentity: verifiedLiveIdentity
        )
      }.value
      await reloadAccountsDuringSwitch()
      guard selectSwitchedInAccount(saved: account, writtenSource: writtenSource, provider: provider) else {
        // The write succeeded but discovery didn't surface the switched-in
        // login (transient read miss); don't claim success on a stale
        // selection — surface it so the user can retry.
        captureErrors[provider] = L10n.string(
          "Switched the CLI login, but Quotari couldn't confirm it yet. Reload accounts."
        )
        return
      }
      captureErrors[provider] = nil
      shouldRefresh = true
    } catch {
      captureErrors[provider] = error.localizedDescription
    }
  }

  /// Claude's refresh token rotates, so its credential fingerprint cannot by
  /// itself prove that a freshly backed-up live slot is the saved account the
  /// user picked. A profile is accepted only when its fingerprint still
  /// matches the source's current access token; UUID is preferred and email
  /// is the fallback stable identity. Passing only a verified source lets the
  /// switch refresh that registry id in place instead of reinstalling its
  /// now-consumed token pair.
  private func knownLiveTarget(for saved: ProviderAccount) -> KnownLiveClaudeTarget? {
    guard saved.provider == .claude else { return nil }
    guard let savedProfile = verifiedClaudeProfile(for: saved) else { return nil }
    let matches = (accounts[.claude] ?? []).compactMap { live -> (ProviderAccount, ClaudeProfile)? in
      guard !live.credentialSource.isCaptured,
            let liveProfile = verifiedClaudeProfile(for: live)
      else { return nil }
      if let savedID = savedProfile.accountID, !savedID.isEmpty,
         let liveID = liveProfile.accountID, !liveID.isEmpty {
        return savedID == liveID ? (live, liveProfile) : nil
      }
      guard let savedEmail = savedProfile.email, !savedEmail.isEmpty,
            let liveEmail = liveProfile.email, !liveEmail.isEmpty
      else { return nil }
      return liveEmail.localizedCaseInsensitiveCompare(savedEmail) == .orderedSame
        ? (live, liveProfile)
        : nil
    }
    let match = matches.first(where: { account, _ in
      if case .claudeKeychain = account.credentialSource {
        return true
      }
      return false
    }) ?? matches.first
    guard let match, let fingerprint = match.1.fingerprint else { return nil }
    return KnownLiveClaudeTarget(
      source: match.0.credentialSource,
      accessTokenFingerprint: fingerprint
    )
  }

  /// Binds the terminal identity snapshot to the exact live credential whose
  /// profile Quotari already verified. Keychain is canonical when present;
  /// the credentials file is used only when no valid Keychain row exists.
  private func verifiedCanonicalLiveClaudeIdentity() -> VerifiedLiveClaudeIdentity? {
    let live = (accounts[.claude] ?? []).filter { !$0.credentialSource.isCaptured }
    let canonical = live.first(where: { account in
      if case .claudeKeychain = account.credentialSource {
        return true
      }
      return false
    }) ?? live.first(where: { account in
      if case .claudeCredentialsFile = account.credentialSource {
        return true
      }
      return false
    })
    guard let canonical,
          let profile = verifiedClaudeProfile(for: canonical),
          let fingerprint = profile.fingerprint
    else { return nil }
    return VerifiedLiveClaudeIdentity(
      source: canonical.credentialSource,
      accessTokenFingerprint: fingerprint,
      profile: profile
    )
  }

  private func verifiedClaudeProfile(for account: ProviderAccount) -> ClaudeProfile? {
    guard let profile = claudeProfiles[account.id],
          profile.hasStableAccountIdentity,
          let expectedFingerprint = profile.fingerprint,
          let credentials = claudeCredentialLoader(account.credentialSource),
          ProviderCredentialIdentity.fingerprint(of: credentials.accessToken) == expectedFingerprint
    else { return nil }
    return profile
  }

  /// Selects the live row that now holds the switched-in login, matching the
  /// exact slot `AccountSwitchService` wrote (the store the CLI reads and the
  /// only one Quotari should refresh) — this disambiguates duplicate Codex
  /// slots and Claude's keychain/file, and keeps an id-less Codex account off
  /// the registry-only refresh path. Anchored to the saved account so a slot
  /// reuse falls back to it. Returns false when that row isn't discoverable.
  private func selectSwitchedInAccount(
    saved: ProviderAccount,
    writtenSource: ProviderCredentialSource,
    provider: UsageProvider
  ) -> Bool {
    guard let liveRow = accounts[provider]?.first(where: { $0.credentialSource == writtenSource }) else {
      return false
    }
    // Anchor only when discovery proved the live credential is the hidden
    // saved copy. This now includes legacy id-less Codex rows through their
    // refresh-token identity, while still refusing to guess for an unmapped
    // login.
    guard capturedEquivalents[liveRow.id]?.id == saved.id else {
      return false
    }
    selectAccount(liveRow, for: provider, standingInFor: saved)
    return true
  }

  /// The live accounts currently flagged as having a hidden saved copy.
  var capturedCopyCandidates: [ProviderAccount] {
    accounts.values.flatMap(\.self).filter { capturedEquivalents.keys.contains($0.id) }
  }

  /// Discovery is the identity proof. Never infer this link from a persisted
  /// selection origin alone: an external relogin can reuse the live slot while
  /// the old origin remains selected.
  func capturedRegistryID(for account: ProviderAccount?) -> String? {
    guard let account, let captured = capturedEquivalents[account.id],
          case let .quotariRegistry(id) = captured.credentialSource
    else { return nil }
    return id
  }

  /// An implicit provider fetch (`account == nil`) follows the provider's
  /// active CLI source. Keep that source's saved-copy link attached to every
  /// refresh so consecutive token rotations form A -> B -> C in the registry
  /// instead of leaving A behind and trying to apply only the final B -> C
  /// grant later.
  func capturedRegistryIDForFetch(
    provider: UsageProvider,
    selectedAccount: ProviderAccount?
  ) -> String? {
    capturedRegistryID(
      for: selectedAccount ?? activeCLIAccounts[provider] ?? accounts[provider]?.first
    )
  }

  /// Hidden saved copies track the live credential's own token rotations —
  /// otherwise a copy could hold an already-consumed refresh token by the
  /// time its CLI slot moves on. Keychain/file I/O runs off the main actor.
  func syncCapturedCopies(of candidates: [ProviderAccount]) async {
    // A linked Claude refresh mirrors the exact accepted grant to the saved
    // id transactionally. Identity-derived sync would instead key off the new
    // refresh token and can never prove the generation transition.
    let candidates = candidates.filter { candidate in
      candidate.provider != .claude || capturedRegistryID(for: candidate) == nil
    }
    guard !candidates.isEmpty else { return }
    let capture = accountCapture
    await Task.detached { capture.syncCapturedCopies(of: candidates) }.value
  }
}
