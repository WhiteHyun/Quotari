import Foundation
import QuotariCore

struct PreservedClaudeLogin {
  let account: ProviderAccount
  let profile: ClaudeProfile
}

enum AddedAccountImportError: LocalizedError {
  case preservationFailed
  case accountSwitchInProgress
  case savedCopyUnverified
  case savedIdentityUnverified
  case savedRegistryIdentityUnverified
  case ambiguousSavedIdentity
  case identityVerificationFailed
  case notRenewable
  case registrySnapshotFailed

  var errorDescription: String? {
    switch self {
    case .preservationFailed:
      "Quotari couldn’t preserve the current CLI account. Resolve the account scan error, then try again."
    case .accountSwitchInProgress:
      "Another account switch started while Quotari was preserving the current account. Try adding the account again."
    case .savedCopyUnverified:
      "Quotari couldn’t verify the saved copy of the current Claude account, so it did not open a new login."
    case .savedIdentityUnverified:
      "Quotari couldn’t verify the current Claude account identity, so it did not open a new login."
    case .savedRegistryIdentityUnverified:
      "Quotari couldn’t verify every saved Claude account, so it did not create a potentially duplicate account."
    case .ambiguousSavedIdentity:
      "More than one saved Claude account has this identity. Resolve the duplicate accounts before logging in again."
    case .identityVerificationFailed:
      "Quotari couldn’t verify the new Claude account identity, so it restored the previous login."
    case .notRenewable:
      "The new login didn’t provide a renewable credential, so Quotari didn’t add it."
    case .registrySnapshotFailed:
      "Quotari couldn’t safely read the saved-account registry, so it did not open a new login."
    }
  }
}
