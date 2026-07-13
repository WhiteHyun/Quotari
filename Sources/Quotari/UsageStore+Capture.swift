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
      try await Task.detached { try capture.capture(account, now: now) }.value
      captureErrors[account.provider] = nil
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
      }
      await reloadAccounts()
    } catch {
      captureErrors[account.provider] = error.localizedDescription
    }
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
