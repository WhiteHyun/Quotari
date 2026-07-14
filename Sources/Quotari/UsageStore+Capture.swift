import Foundation
import QuotariCore

// MARK: - Saving accounts into the Quotari registry

extension UsageStore {
  /// Snapshots the account's live credentials into Quotari's own registry so
  /// it survives the CLI credential slot being reused by another login. The
  /// keychain/file I/O runs off the main actor so a slow (or prompting)
  /// `security` call can't freeze the popover.
  func captureAccount(_ account: ProviderAccount) async {
    let capture = accountCapture
    let now = Date()
    do {
      let captured = try await Task.detached { try capture.capture(account, now: now) }.value
      captureErrors[account.provider] = nil
      // The saved copy's email label is resolved by its own profile fetch on
      // the reload below — not seeded from the live row, whose stable id can
      // carry a stale profile if the CLI login changed between discovery and
      // Save (which would mislabel the saved account).
      // Saving the selected live login makes the selection logically the
      // saved account, with the live login as its stand-in — so a later slot
      // reuse falls back to the saved copy instead of following the slot.
      if selectedAccounts[account.provider]?.id == account.id {
        let origin = ProviderAccount(
          provider: captured.provider,
          displayName: captured.displayName,
          detail: captured.detail ?? "Saved in Quotari",
          credentialSource: .quotariRegistry(id: captured.id)
        )
        selectAccount(account, for: account.provider, standingInFor: origin)
      }
      await reloadAccounts()
    } catch {
      captureErrors[account.provider] = error.localizedDescription
    }
  }

  func removeCapturedAccount(_ account: ProviderAccount) async {
    guard case let .quotariRegistry(id) = account.credentialSource else { return }
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
  /// suppressed while the identity is live, so the live row hosts the action.
  func removeCapturedCopy(of account: ProviderAccount) async {
    let capture = accountCapture
    do {
      let removedID = try await Task.detached { try capture.removeCapturedCopy(of: account) }.value
      captureErrors[account.provider] = nil
      if let origin = reconciledSelectionOrigins[account.provider],
         case let .quotariRegistry(originID) = origin.credentialSource, originID == removedID {
        selectAccount(selectedAccounts[account.provider], for: account.provider, standingInFor: nil)
      }
      await reloadAccounts()
    } catch {
      captureErrors[account.provider] = error.localizedDescription
    }
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
      captureErrors[provider] = "Another account switch is already in progress."
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
      if shouldRefresh {
        // A selection refresh created during reload can observe the closed
        // gate and exit. Replace it after opening the gate so every successful
        // switch performs exactly one serialized fetch of the live slot.
        enqueueSelectionRefresh(for: provider)
      }
    }
    // Drain whatever was already running when the gate closed.
    await inFlightRefresh?.value
    await accountUsageRefreshTasks[provider]?.task.value
    await selectionRefreshTasks[provider]?.value
    let switcher = accountSwitch
    let knownLiveTarget = knownLiveTarget(for: account)
    let now = Date()
    do {
      // The write runs detached (off the main actor), and `isSwitching`
      // suppresses Quotari refreshes for the window. The switch service also
      // checks separate CLI processes; the confirmation explains its residual
      // non-cooperative launch window.
      let writtenSource = try await Task.detached {
        try switcher.switchCLI(
          toRegistryAccount: id,
          now: now,
          knownLiveTarget: knownLiveTarget
        )
      }.value
      await reloadAccounts()
      guard selectSwitchedInAccount(saved: account, writtenSource: writtenSource, provider: provider) else {
        // The write succeeded but discovery didn't surface the switched-in
        // login (transient read miss); don't claim success on a stale
        // selection — surface it so the user can retry.
        captureErrors[provider] = "Switched the CLI login, but Quotari couldn't confirm it yet. Reload accounts."
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

  private func verifiedClaudeProfile(for account: ProviderAccount) -> ClaudeProfile? {
    guard let profile = claudeProfiles[account.id],
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
  /// first discovered live source, matching credential resolution order. Keep
  /// that source's saved-copy link attached to every refresh so consecutive
  /// token rotations form A -> B -> C in the registry instead of leaving A
  /// behind and trying to apply only the final B -> C grant later.
  func capturedRegistryIDForFetch(
    provider: UsageProvider,
    selectedAccount: ProviderAccount?
  ) -> String? {
    capturedRegistryID(for: selectedAccount ?? accounts[provider]?.first)
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
