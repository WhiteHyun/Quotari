import Foundation
@testable import QuotariCore
import Testing

struct ClaudeProfileFetcherTests {
  @Test func parsesNestedAccountEmailAndOrganizationName() async throws {
    let recorder = ProfileStubTransport.Recorder()
    let transport = ProfileStubTransport(
      json: #"{"account":{"uuid":"u1","email":"dev@example.com"},"organization":{"uuid":"o1","name":"Acme"}}"#,
      recorder: recorder
    )

    let profile = try await ClaudeProfileFetcher(transport: transport).fetchProfile(accessToken: "tok")

    let request = try #require(recorder.requests.first)
    #expect(request.url == ClaudeProfileFetcher.profileURL)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(profile.accountID == "u1")
    #expect(profile.email == "dev@example.com")
    #expect(profile.organizationID == "o1")
    #expect(profile.organizationName == "Acme")
  }

  @Test func toleratesMissingOrganizationName() async throws {
    let transport = ProfileStubTransport(
      json: #"{"account":{"uuid":"u1","email":"solo@example.com"},"organization":{"uuid":"o1"}}"#
    )

    let profile = try await ClaudeProfileFetcher(transport: transport).fetchProfile(accessToken: "tok")

    #expect(profile.email == "solo@example.com")
    #expect(profile.organizationID == "o1")
    #expect(profile.organizationName == nil)
  }

  @Test func emptyBodyYieldsEmptyProfile() async throws {
    let transport = ProfileStubTransport(json: "{}")
    let profile = try await ClaudeProfileFetcher(transport: transport).fetchProfile(accessToken: "tok")
    #expect(profile.isEmpty)
  }

  @Test func unauthorizedSurfacesHTTPError() async {
    let transport = ProfileStubTransport(json: #"{"error":"unauthorized"}"#, status: 401)
    await #expect(throws: ProviderHTTPError.self) {
      _ = try await ClaudeProfileFetcher(transport: transport).fetchProfile(accessToken: "tok")
    }
  }
}

struct ClaudeProfileStoreTests {
  @Test func roundTripsProfilesToDisk() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-profiles-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = ClaudeProfileStore(url: url)

    var profile = ClaudeProfile(
      email: "a@b.com",
      organizationID: "organization-uuid",
      organizationName: "Org",
      fingerprint: "access-fingerprint"
    )
    profile.accountID = "account-uuid"
    try store.save(["claude:keychain": profile])
    let loaded = store.load()

    #expect(loaded["claude:keychain"]?.accountID == "account-uuid")
    #expect(loaded["claude:keychain"]?.email == "a@b.com")
    #expect(loaded["claude:keychain"]?.organizationID == "organization-uuid")
    #expect(loaded["claude:keychain"]?.organizationName == "Org")
    #expect(loaded["claude:keychain"]?.fingerprint == "access-fingerprint")
  }

  @Test func loadsAProfilePersistedBeforeAccountIDsWereAdded() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-profiles-legacy-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"claude:keychain":{"email":"legacy@example.com","fingerprint":"legacy-fingerprint"}}"#.utf8)
      .write(to: url)

    let profile = try #require(ClaudeProfileStore(url: url).load()["claude:keychain"])

    #expect(profile.accountID == nil)
    #expect(profile.email == "legacy@example.com")
    #expect(profile.organizationID == nil)
    #expect(profile.fingerprint == "legacy-fingerprint")
  }

  @Test func missingFileLoadsEmpty() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-profiles-missing-\(UUID().uuidString).json")
    #expect(ClaudeProfileStore(url: url).load().isEmpty)
  }
}

struct ClaudeAccountIdentityTests {
  @Test func exactKeyNormalizesIdentifiersAndEmail() {
    let identity = ClaudeAccountIdentity(
      accountID: "  ACCOUNT-ID\n",
      email: " User@Example.COM ",
      organizationID: " ORG-ID "
    )

    #expect(identity.accountID == "account-id")
    #expect(identity.email == "user@example.com")
    #expect(identity.organizationID == "org-id")
    #expect(identity.key == .account("account-id", organizationID: "org-id"))
    #expect(identity.isStrong)
  }

  @Test func missingOrganizationIsNotAWildcardForAUUIDIdentity() {
    let weak = ClaudeAccountIdentity(accountID: "account", email: "user@example.com")
    let strong = ClaudeAccountIdentity(
      accountID: "account",
      email: "user@example.com",
      organizationID: "organization"
    )

    #expect(weak.isUsable)
    #expect(!weak.isStrong)
    #expect(!weak.identifiesSameAccount(as: strong))
  }

  @Test func emailOnlyIdentityCannotBridgeToUUIDIdentity() {
    let emailOnly = ClaudeAccountIdentity(email: "user@example.com", organizationID: "organization")
    let uuidIdentity = ClaudeAccountIdentity(
      accountID: "account",
      email: "user@example.com",
      organizationID: "organization"
    )

    #expect(emailOnly.key == .email("user@example.com", organizationID: "organization"))
    #expect(!emailOnly.identifiesSameAccount(as: uuidIdentity))
  }

  @Test func organizationScopesOtherwiseIdenticalAccountUUIDs() {
    let first = ClaudeAccountIdentity(accountID: "account", organizationID: "organization-a")
    let second = ClaudeAccountIdentity(accountID: "account", organizationID: "organization-b")

    #expect(first.isStrong)
    #expect(second.isStrong)
    #expect(!first.identifiesSameAccount(as: second))
  }
}

private struct ProfileStubTransport: ProviderHTTPTransport {
  let body: Data
  let status: Int
  let recorder: Recorder?

  final class Recorder: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) {
      requests.append(request)
    }
  }

  init(json: String, status: Int = 200, recorder: Recorder? = nil) {
    body = Data(json.utf8)
    self.status = status
    self.recorder = recorder
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorder?.record(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}
