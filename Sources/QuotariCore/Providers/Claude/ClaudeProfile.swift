import Foundation

/// The identifying bits of a Claude account the usage endpoint doesn't report.
/// Fetched from the OAuth profile endpoint so a Claude account can be labeled
/// by its email instead of the generic "Claude Code".
public struct ClaudeProfile: Codable, Equatable, Sendable {
  /// Stable account UUID returned by Claude's profile endpoint. Unlike OAuth
  /// token fingerprints, this survives ordinary access/refresh rotation.
  public var accountID: String?
  public var email: String?
  public var organizationID: String?
  public var organizationName: String?
  /// The access-token fingerprint this profile was fetched for. Drives retry
  /// eligibility (any token change re-enables one fetch) and recognizing a
  /// cache entry left over from a now-replaced token.
  public var fingerprint: String?

  public init(
    accountID: String? = nil,
    email: String? = nil,
    organizationID: String? = nil,
    organizationName: String? = nil,
    fingerprint: String? = nil
  ) {
    self.accountID = accountID
    self.email = email
    self.organizationID = organizationID
    self.organizationName = organizationName
    self.fingerprint = fingerprint
  }

  public var isEmpty: Bool {
    (accountID?.isEmpty ?? true)
      && (email?.isEmpty ?? true)
      && (organizationID?.isEmpty ?? true)
      && (organizationName?.isEmpty ?? true)
  }
}

public protocol ClaudeProfileFetching: Sendable {
  func fetchProfile(accessToken: String) async throws -> ClaudeProfile
}

/// Reads `/api/oauth/profile`, the same endpoint Claude Code uses to resolve
/// the signed-in account. The response shape (verified against Claude Code
/// 2.1.207) is `{ account: { uuid, email }, organization: { uuid, ... } }`;
/// email is guaranteed, organization name only when the passthrough carries it.
public struct ClaudeProfileFetcher: ClaudeProfileFetching {
  public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

  private let transport: any ProviderHTTPTransport
  private let profileURL: URL

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    profileURL: URL = ClaudeProfileFetcher.profileURL
  ) {
    self.transport = transport
    self.profileURL = profileURL
  }

  public func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    let data = try await transport.getJSON(
      url: profileURL,
      bearer: accessToken,
      headers: ["anthropic-beta": "oauth-2025-04-20", "Cache-Control": "no-cache"]
    )
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let account = root["account"] as? [String: Any]
    let organization = root["organization"] as? [String: Any]
    return ClaudeProfile(
      accountID: string(account?["uuid"]),
      email: string(account?["email"]) ?? string(root["account_email"]),
      organizationID: string(organization?["uuid"]),
      organizationName: string(organization?["name"]) ?? string(root["organization_name"])
    )
  }

  private func string(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
  }
}

/// Persists fetched profiles keyed by the account's stable id, so the email
/// label survives relaunches and Quotari doesn't re-hit the profile endpoint
/// on every usage refresh.
public struct ClaudeProfileStore: Sendable {
  public let url: URL

  public init(url: URL = Self.defaultURL()) {
    self.url = url
  }

  public static func defaultURL(
    fileManager: FileManager = .default,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? home.appendingPathComponent("Library/Application Support")
    return base
      .appendingPathComponent("Quotari", isDirectory: true)
      .appendingPathComponent("ClaudeProfiles.json")
  }

  public func load() -> [String: ClaudeProfile] {
    guard let data = try? Data(contentsOf: url),
          let profiles = try? JSONDecoder().decode([String: ClaudeProfile].self, from: data)
    else { return [:] }
    return profiles
  }

  public func save(_ profiles: [String: ClaudeProfile]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(profiles).write(to: url, options: [.atomic])
  }
}
