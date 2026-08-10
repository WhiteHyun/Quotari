import QuotariCore

extension UsageStore {
  private static let weakClaudeIdentityDuplicateMessageKey =
    "Quotari found saved Claude accounts that may be duplicates, but their identity details are incomplete. "
      + "They were kept separate to avoid merging different accounts."

  static var weakClaudeIdentityDuplicateMessage: String {
    L10n.string(key: weakClaudeIdentityDuplicateMessageKey)
  }

  func recordAutomaticCaptureMessages(
    _ failures: [String],
    provider: UsageProvider
  ) async {
    captureErrors[provider] = failures.isEmpty ? nil : failures.joined(separator: "\n")
    captureWarnings[provider] = if provider == .claude,
                                   await hasPotentialWeakClaudeDuplicate() {
      Self.weakClaudeIdentityDuplicateMessage
    } else {
      nil
    }
  }

  /// Weak identity is deliberately insufficient for automatic merge or
  /// deletion. Keep the rows intact, but surface their ambiguity on every
  /// account reload so later external token rotations cannot accumulate
  /// additional saved generations without the user seeing it.
  private func hasPotentialWeakClaudeDuplicate() async -> Bool {
    let identities = await savedClaudeAccounts().compactMap(\.claudeAccountIdentity)
    guard identities.count > 1 else { return false }
    return identities.indices.dropLast().contains { index in
      identities[identities.index(after: index)...].contains {
        identities[index].mayBeWeakDuplicate(of: $0)
      }
    }
  }
}

private extension ClaudeAccountIdentity {
  /// A warning-only, deliberately non-transitive comparison. Missing evidence
  /// can suggest a duplicate but can never authorize row mutation.
  func mayBeWeakDuplicate(of other: Self) -> Bool {
    guard !isStrong || !other.isStrong,
          Self.isCompatible(accountID, other.accountID),
          Self.isCompatible(organizationID, other.organizationID)
    else { return false }

    if let accountID, let otherAccountID = other.accountID {
      return accountID == otherAccountID
    }
    guard let email, let otherEmail = other.email else { return false }
    return email == otherEmail
  }

  static func isCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
    lhs == nil || rhs == nil || lhs == rhs
  }
}
