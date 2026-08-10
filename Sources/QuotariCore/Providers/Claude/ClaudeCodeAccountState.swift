import Foundation

/// Reads and replaces Claude Code's non-secret account identity snapshot in
/// `~/.claude.json` or `$CLAUDE_CONFIG_DIR/.claude.json`. Claude authenticates with the Keychain credential, but
/// `claude auth status` and new terminal sessions label that credential from
/// this separate `oauthAccount` object, so an account switch must keep both in
/// sync.
public enum ClaudeCodeAccountState {
  static func configurationURL(environment: [String: String], home: URL) -> URL {
    let configuredDirectory = environment["CLAUDE_CONFIG_DIR"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let directory = if let configuredDirectory, !configuredDirectory.isEmpty {
      URL(fileURLWithPath: configuredDirectory, isDirectory: true)
    } else {
      home
    }
    return directory.appendingPathComponent(".claude.json")
  }

  public static func oauthAccount(from configuration: Data?) throws -> Data? {
    guard let configuration else { return nil }
    let root = try jsonObject(configuration)
    guard let account = root["oauthAccount"] as? [String: Any] else { return nil }
    return try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
  }

  public static func replacingOAuthAccount(
    in configuration: Data?,
    with oauthAccount: Data
  ) throws -> Data {
    var root = try configuration.map(jsonObject) ?? [:]
    root["oauthAccount"] = try jsonObject(oauthAccount)
    return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
  }

  public static func matches(_ oauthAccount: Data, profile: ClaudeProfile) -> Bool {
    guard let account = try? jsonObject(oauthAccount) else { return false }
    let expectedIdentity = ClaudeAccountIdentity(profile: profile)
    let actualIdentity = ClaudeAccountIdentity(
      accountID: account["accountUuid"] as? String,
      email: account["emailAddress"] as? String,
      organizationID: account["organizationUuid"] as? String
    )
    if let expectedOrganization = expectedIdentity.organizationID,
       expectedOrganization != actualIdentity.organizationID {
      return false
    }
    if let expected = expectedIdentity.accountID,
       let actual = actualIdentity.accountID {
      return expected == actual
    }
    guard let expected = expectedIdentity.email,
          let actual = actualIdentity.email
    else { return false }
    return expected == actual
  }

  /// Legacy Quotari rows predate exact `oauthAccount` snapshots. Build the
  /// smallest identity object Claude Code needs from the profile Quotari just
  /// verified against that row's access token. Organization-level fields may
  /// be inherited only when the organization name agrees; account-specific
  /// subscription fields are intentionally not copied from the old login.
  public static func synthesizedOAuthAccount(
    for profile: ClaudeProfile,
    template: Data? = nil
  ) throws -> Data {
    var account: [String: Any] = [:]
    if let accountID = nonempty(profile.accountID) {
      account["accountUuid"] = accountID
    }
    if let email = nonempty(profile.email) {
      account["emailAddress"] = email
    }
    if let organizationName = nonempty(profile.organizationName) {
      account["organizationName"] = organizationName
    }
    if let organizationID = nonempty(profile.organizationID) {
      account["organizationUuid"] = organizationID
    }

    if let template,
       let templateAccount = try? jsonObject(template),
       sameOrganization(templateAccount, profile: profile) {
      for key in ["organizationUuid", "organizationType", "organizationRateLimitTier"]
        where account[key] == nil {
        account[key] = templateAccount[key]
      }
    }
    account["profileFetchedAt"] = 0
    return try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
  }

  private static func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CocoaError(.propertyListReadCorrupt)
    }
    return object
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func sameOrganization(_ account: [String: Any], profile: ClaudeProfile) -> Bool {
    guard let expected = nonempty(profile.organizationName),
          let actual = nonempty(account["organizationName"] as? String)
    else { return false }
    return expected.localizedCaseInsensitiveCompare(actual) == .orderedSame
  }
}
