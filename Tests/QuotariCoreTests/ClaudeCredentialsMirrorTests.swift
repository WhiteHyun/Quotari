import Foundation
@testable import QuotariCore
import Testing

struct ClaudeCredentialsMirrorTests {
  private static let storedPayload = """
  {
    "claudeAiOauth": {
      "accessToken": "old-tok",
      "refreshToken": "old-ref",
      "expiresAt": 1000,
      "refreshTokenExpiresAt": 99999,
      "scopes": ["user:inference"],
      "subscriptionType": "max",
      "rateLimitTier": "default_claude_max_20x"
    },
    "mcpOAuth": {
      "linear|abc": {"accessToken": "mcp-tok", "serverUrl": "https://mcp.linear.app"}
    }
  }
  """

  @Test func canonicalKeychainRotationMirrorsAMatchingExistingFile() throws {
    final class Box: @unchecked Sendable { var keychainData: Data? }
    let box = Box()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-mirror-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(".credentials.json")
    let filePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"old-tok","refreshToken":"old-ref"},"fileOnly":"kept"}"#.utf8
    )
    try filePayload.write(to: url)
    let store = CapturedAccountStore(
      keychain: InMemoryKeychain().store,
      service: "Test-ClaudeCanonicalMirror-\(UUID().uuidString)"
    )
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in Data(Self.storedPayload.utf8) },
      keychainWrite: { data, _ in box.keychainData = data },
      capturedAccounts: store,
      mirroredCredentialsFileURL: url
    )

    try writer.persist(
      ClaudeTokenGrant(accessToken: "new-tok", refreshToken: "new-ref"),
      replacing: "old-tok",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    let keychainData = try #require(box.keychainData)
    let keychainObject = try JSONSerialization.jsonObject(with: keychainData)
    let keychainRoot = try #require(keychainObject as? [String: Any])
    let fileData = try Data(contentsOf: url)
    let fileRoot = try #require(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
    #expect((keychainRoot["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "new-tok")
    #expect(keychainRoot["mcpOAuth"] != nil)
    #expect((fileRoot["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "new-tok")
    #expect(fileRoot["fileOnly"] as? String == "kept")
    #expect(fileRoot["mcpOAuth"] == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
  }

  @Test func failedMirrorCommitPreservesTheRotatedGrantForTheFileSource() throws {
    final class Box: @unchecked Sendable { var keychainData: Data? }
    let box = Box()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-failed-mirror-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(".credentials.json")
    let original = Data(Self.storedPayload.utf8)
    try original.write(to: url)
    let store = CapturedAccountStore(
      keychain: InMemoryKeychain().store,
      service: "Test-ClaudeMirror-\(UUID().uuidString)"
    )
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in original },
      keychainWrite: { data, _ in box.keychainData = data },
      capturedAccounts: store,
      mirroredCredentialsFileURL: url,
      commitMirroredFile: { _, _ in throw CocoaError(.fileWriteUnknown) }
    )
    let grant = ClaudeTokenGrant(accessToken: "new-tok", refreshToken: "new-ref")

    expectClaudeMirrorRecoveryFailure(writer, grant, replacing: "old-tok")

    #expect(try ClaudeCredentialsStore.parse(#require(box.keychainData)).accessToken == "new-tok")
    #expect(try Data(contentsOf: url) == original)
    let fileSource = ProviderCredentialSource.claudeCredentialsFile(path: url.standardizedFileURL.path)
    let pendingID = try #require(fileSource.claudeLivePendingGrantID)
    let pendingData = try #require(store.pendingGrantData(id: pendingID))
    let pending = try JSONDecoder().decode(ClaudePendingGrant.self, from: pendingData)
    let expected = ClaudePendingGrant(
      grant: grant,
      previousAccessToken: "old-tok",
      consumedRefreshToken: "old-ref"
    )
    #expect(pending == expected)
    let keychainSource = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let keychainPendingID = try #require(keychainSource.claudeLivePendingGrantID)
    let keychainPendingData = try #require(store.pendingGrantData(id: keychainPendingID))
    #expect(try JSONDecoder().decode(ClaudePendingGrant.self, from: keychainPendingData) == expected)
  }

  @Test func canonicalRotationMirrorsAFileSharingTheConsumedRefreshGeneration() throws {
    final class Box: @unchecked Sendable { var keychainData: Data? }
    let box = Box()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-shared-refresh-mirror-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(".credentials.json")
    let filePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"file-old-tok","refreshToken":"old-ref"},"fileOnly":"kept"}"#.utf8
    )
    try filePayload.write(to: url)
    let store = CapturedAccountStore(
      keychain: InMemoryKeychain().store,
      service: "Test-ClaudeSharedRefreshMirror-\(UUID().uuidString)"
    )
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in Data(Self.storedPayload.utf8) },
      keychainWrite: { data, _ in box.keychainData = data },
      capturedAccounts: store,
      mirroredCredentialsFileURL: url
    )

    try writer.persist(
      ClaudeTokenGrant(accessToken: "new-tok", refreshToken: "new-ref"),
      replacing: "old-tok",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    let fileData = try Data(contentsOf: url)
    let fileRoot = try #require(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
    let oauth = try #require(fileRoot["claudeAiOauth"] as? [String: Any])
    #expect(oauth["accessToken"] as? String == "new-tok")
    #expect(oauth["refreshToken"] as? String == "new-ref")
    #expect(fileRoot["fileOnly"] as? String == "kept")
  }

  @Test func changedMatchingMirrorPreservesTheRotatedGrant() throws {
    final class Box: @unchecked Sendable {
      var keychainData: Data?
      var reads = 0
    }
    let box = Box()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-changed-mirror-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(".credentials.json")
    let original = Data(Self.storedPayload.utf8)
    let changed = Data(
      #"{"claudeAiOauth":{"accessToken":"old-tok","refreshToken":"old-ref"},"external":"changed"}"#.utf8
    )
    try original.write(to: url)
    let store = CapturedAccountStore(
      keychain: InMemoryKeychain().store,
      service: "Test-ClaudeChangedMirror-\(UUID().uuidString)"
    )
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in original },
      keychainWrite: { data, _ in box.keychainData = data },
      capturedAccounts: store,
      mirroredCredentialsFileURL: url,
      fileRead: { destination in
        box.reads += 1
        if box.reads == 2 {
          try changed.write(to: destination)
        }
        return try Data(contentsOf: destination)
      }
    )
    let grant = ClaudeTokenGrant(accessToken: "new-tok", refreshToken: "new-ref")

    expectClaudeMirrorRecoveryFailure(writer, grant, replacing: "old-tok")

    #expect(try ClaudeCredentialsStore.parse(#require(box.keychainData)).accessToken == "new-tok")
    #expect(try Data(contentsOf: url) == changed)
    let fileSource = ProviderCredentialSource.claudeCredentialsFile(path: url.standardizedFileURL.path)
    let pendingID = try #require(fileSource.claudeLivePendingGrantID)
    let pendingData = try #require(store.pendingGrantData(id: pendingID))
    let pending = try JSONDecoder().decode(ClaudePendingGrant.self, from: pendingData)
    #expect(pending == ClaudePendingGrant(
      grant: grant,
      previousAccessToken: "old-tok",
      consumedRefreshToken: "old-ref"
    ))
  }

  @Test func keychainRotationDoesNotTouchAnUnrelatedMirroredFile() throws {
    final class Box: @unchecked Sendable { var keychainData: Data? }
    let box = Box()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-unrelated-mirror-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(".credentials.json")
    let unrelated = Data(
      #"{"claudeAiOauth":{"accessToken":"other-tok","refreshToken":"other-ref"}}"#.utf8
    )
    try unrelated.write(to: url)
    let writer = ClaudeCredentialsWriter(
      keychainRead: { _ in Data(Self.storedPayload.utf8) },
      keychainWrite: { data, _ in box.keychainData = data },
      mirroredCredentialsFileURL: url
    )

    try writer.persist(
      ClaudeTokenGrant(accessToken: "new-tok"),
      replacing: "old-tok",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )

    #expect(try ClaudeCredentialsStore.parse(#require(box.keychainData)).accessToken == "new-tok")
    #expect(try Data(contentsOf: url) == unrelated)
  }

  @Test func keychainRotationNeverCreatesAMissingMirrorOrTouchesItForACustomService() throws {
    final class Box: @unchecked Sendable { var writes = 0 }
    let box = Box()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-no-mirror-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("missing.json")
    let custom = directory.appendingPathComponent("custom.json")
    let original = Data(Self.storedPayload.utf8)
    try original.write(to: custom)
    let missingWriter = ClaudeCredentialsWriter(
      keychainRead: { _ in original },
      keychainWrite: { _, _ in box.writes += 1 },
      mirroredCredentialsFileURL: missing
    )
    try missingWriter.persist(
      ClaudeTokenGrant(accessToken: "new-tok"),
      replacing: "old-tok",
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )
    let customWriter = ClaudeCredentialsWriter(
      keychainRead: { _ in original },
      keychainWrite: { _, _ in box.writes += 1 },
      mirroredCredentialsFileURL: custom
    )
    try customWriter.persist(
      ClaudeTokenGrant(accessToken: "new-tok"),
      replacing: "old-tok",
      to: .claudeKeychain(service: "Custom-Service")
    )

    #expect(box.writes == 2)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    #expect(try Data(contentsOf: custom) == original)
  }
}
