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

  /// The live accounts currently flagged as having a hidden saved copy.
  var capturedCopyCandidates: [ProviderAccount] {
    accounts.values.flatMap(\.self).filter { capturedEquivalents.keys.contains($0.id) }
  }

  /// Hidden saved copies track the live credential's own token rotations —
  /// otherwise a copy could hold an already-consumed refresh token by the
  /// time its CLI slot moves on. Keychain/file I/O runs off the main actor.
  func syncCapturedCopies(of candidates: [ProviderAccount]) async {
    guard !candidates.isEmpty else { return }
    let capture = accountCapture
    await Task.detached { capture.syncCapturedCopies(of: candidates) }.value
  }
}
