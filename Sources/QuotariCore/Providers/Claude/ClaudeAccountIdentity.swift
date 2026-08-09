import Foundation

/// A token-independent Claude account identity persisted with a captured row.
/// Tokens and profile-fetch fingerprints deliberately stay out of this value:
/// they identify credential generations, while this value identifies the
/// remote account and organization that own those generations.
public struct ClaudeAccountIdentity: Codable, Equatable, Hashable, Sendable {
  public var accountID: String?
  public var email: String?
  public var organizationID: String?

  public init(
    accountID: String? = nil,
    email: String? = nil,
    organizationID: String? = nil
  ) {
    self.accountID = Self.normalizedIdentifier(accountID)
    self.email = Self.normalizedEmail(email)
    self.organizationID = Self.normalizedIdentifier(organizationID)
  }

  public init(profile: ClaudeProfile) {
    self.init(
      accountID: profile.accountID,
      email: profile.email,
      organizationID: profile.organizationID
    )
  }

  /// Identity is usable for non-destructive account linking. A profile that
  /// only carries a display organization name is not identity evidence.
  public var isUsable: Bool {
    accountID != nil || email != nil
  }

  /// Destructive consolidation requires both server-issued identifiers.
  /// Email-only legacy profiles are useful labels, but never deletion proof.
  public var isStrong: Bool {
    accountID != nil && organizationID != nil
  }

  /// Exact, transitive key. Missing fields are values, never wildcards, and a
  /// UUID-bearing identity can never be bridged through an email-only profile.
  public var key: Key? {
    if let accountID {
      return .account(accountID, organizationID: organizationID)
    }
    guard let email else { return nil }
    return .email(email, organizationID: organizationID)
  }

  public func identifiesSameAccount(as other: Self) -> Bool {
    guard let key, let otherKey = other.key else { return false }
    return key == otherKey
  }

  /// Monotonically enriches identity evidence after an exact credential or
  /// explicit-row proof. Missing values never erase stored server identifiers;
  /// explicit account or organization conflicts fail closed, and weak evidence
  /// never downgrades a strong identity.
  func merged(with candidate: Self) -> Self? {
    switch (isStrong, candidate.isStrong) {
    case (true, true):
      guard key == candidate.key else { return nil }
      return Self(
        accountID: accountID,
        email: candidate.email ?? email,
        organizationID: organizationID
      )
    case (true, false):
      guard Self.compatible(accountID, candidate.accountID),
            Self.compatible(organizationID, candidate.organizationID)
      else { return nil }
      return self
    case (false, true):
      guard Self.compatible(accountID, candidate.accountID),
            Self.compatible(organizationID, candidate.organizationID)
      else { return nil }
      return Self(
        accountID: candidate.accountID,
        email: candidate.email ?? email,
        organizationID: candidate.organizationID
      )
    case (false, false):
      guard Self.compatible(accountID, candidate.accountID),
            Self.compatible(organizationID, candidate.organizationID)
      else { return nil }
      return Self(
        accountID: candidate.accountID ?? accountID,
        email: candidate.email ?? email,
        organizationID: candidate.organizationID ?? organizationID
      )
    }
  }

  public enum Key: Codable, Equatable, Hashable, Sendable {
    case account(String, organizationID: String?)
    case email(String, organizationID: String?)
  }

  private static func normalizedIdentifier(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value.lowercased()
  }

  private static func normalizedEmail(_ value: String?) -> String? {
    normalizedIdentifier(value)
  }

  private static func compatible(_ lhs: String?, _ rhs: String?) -> Bool {
    lhs == nil || rhs == nil || lhs == rhs
  }
}

public extension ClaudeProfile {
  var accountIdentity: ClaudeAccountIdentity? {
    let identity = ClaudeAccountIdentity(profile: self)
    return identity.isUsable ? identity : nil
  }

  var hasStableAccountIdentity: Bool {
    accountIdentity != nil
  }

  var hasStrongAccountIdentity: Bool {
    accountIdentity?.isStrong == true
  }

  /// Required before an inferred match may overwrite or delete a saved row.
  /// Account UUID and organization UUID must both be present on both sides.
  func stronglyIdentifiesSameAccount(as other: ClaudeProfile) -> Bool {
    guard let accountIdentity, accountIdentity.isStrong,
          let otherIdentity = other.accountIdentity, otherIdentity.isStrong
    else { return false }
    return accountIdentity.identifiesSameAccount(as: otherIdentity)
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
}
