import Foundation
import QuotariCore

extension ClaudeProfile {
  var hasStableAccountIdentity: Bool {
    normalizedAccountID != nil || normalizedEmail != nil
  }

  func identifiesSameAccount(as other: ClaudeProfile) -> Bool {
    if let leftID = normalizedAccountID,
       let rightID = other.normalizedAccountID {
      return leftID == rightID
    }
    guard let leftEmail = normalizedEmail,
          let rightEmail = other.normalizedEmail
    else { return false }
    return leftEmail.localizedCaseInsensitiveCompare(rightEmail) == .orderedSame
  }

  func verified(for fingerprint: String) -> ClaudeProfile {
    ClaudeProfile(
      accountID: accountID,
      email: email,
      organizationID: organizationID,
      organizationName: organizationName,
      fingerprint: fingerprint
    )
  }

  private var normalizedAccountID: String? {
    accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private var normalizedEmail: String? {
    email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
