import Foundation
@testable import QuotariCore
import Testing

extension CodexAuthStorageTests {
  @Test func malformedKeyringPayloadFallsBackOnlyInAutoMode() throws {
    for malformed in malformedCodexPayloads() {
      let autoHome = try codexHome(mode: "auto")
      defer { try? FileManager.default.removeItem(at: autoHome) }
      let fallback = codexPayload(account: "acct-file", token: "file-tok", refresh: "file-ref")
      let autoStorage = CodexAuthStorage(environment: [:], home: autoHome, keychainRead: { _, _ in malformed })
      try writeSecure(fallback, to: autoStorage.authFileURL)

      let snapshot = try autoStorage.snapshot()

      #expect(snapshot.source == .codexAuthFile(path: autoStorage.authFileURL.path))
      #expect(snapshot.payload == fallback)
      #expect(snapshot.keyringState == .unavailable)

      let keyringHome = try codexHome(mode: "keyring")
      defer { try? FileManager.default.removeItem(at: keyringHome) }
      let keyringStorage = CodexAuthStorage(
        environment: [:],
        home: keyringHome,
        keychainRead: { _, _ in malformed }
      )
      #expect(throws: CodexCredentialsError.self) {
        _ = try keyringStorage.snapshot()
      }
    }
  }

  func malformedCodexPayloads() -> [Data] {
    [
      Data("{truncated".utf8),
      Data(#"{"tokens":[]}"#.utf8),
      Data(
        #"{"last_refresh":"not-a-date","tokens":{"id_token":"e30.e30.sig","access_token":"tok","refresh_token":"ref"}}"#
          .utf8
      ),
      Data(
        #"{"last_refresh":"2026-02-30T00:00:00Z","tokens":{"id_token":"e30.e30.sig","access_token":"tok","refresh_token":"ref"}}"#
          .utf8
      ),
      Data(#"{"tokens":{"id_token":"not-a-jwt","access_token":"tok","refresh_token":"ref"}}"#.utf8),
      Data(
        #"{"tokens":{"id_token":"e30.eyJlbWFpbCI6IngifQ==.sig","access_token":"tok","refresh_token":"ref"}}"#.utf8
      ),
      Data(
        #"{"tokens":{"id_token":"e30.eyJlbWFpbCI6MTIzfQ.sig","access_token":"tok","refresh_token":"ref"}}"#.utf8
      ),
      Data(
        #"{"tokens":{"id_token":"e30.eyJlbWFpbCI6IngifR.sig","access_token":"tok","refresh_token":"ref"}}"#.utf8
      ),
      Data(
        #"""
        {"tokens":{
          "id_token":"e30.eyJlbWFpbCI6IngiLCJlbWFpbCI6MTIzfQ.sig",
          "access_token":"tok","refresh_token":"ref"
        }}
        """#.utf8
      ),
      Data(
        #"{"tokens":{"id_token":"e30.e30.sig","access_token":"tok","refresh_token":"ref"},"tokens":[]}"#.utf8
      ),
      Data(
        #"{"unknown":tru,"tokens":{"id_token":"e30.e30.sig","access_token":"tok","refresh_token":"ref"}}"#.utf8
      ),
    ]
  }

  func deeplyNestedCodexPayload(depth: Int) -> Data {
    let nested = String(repeating: "[", count: depth) + "null" + String(repeating: "]", count: depth)
    return Data(
      """
      {"unknown":\(nested),"tokens":{
        "id_token":"e30.e30.sig","access_token":"tok","refresh_token":"ref"
      }}
      """.utf8
    )
  }

  @Test func deeplyNestedUnknownKeyringFieldIsAccepted() throws {
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let payload = deeplyNestedCodexPayload(depth: 5000)
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: { _, _ in payload })

    let snapshot = try storage.snapshot()
    let snapshotPayload = try #require(snapshot.payload)

    #expect(snapshot.source == storage.keychainSource)
    #expect(snapshot.payload == payload)
    #expect(snapshot.keyringState == .available)
    #expect(try CodexCredentialsStore.parse(snapshotPayload).accessToken == "tok")
  }

  @Test func duplicateKeyValidatorUsesAnExplicitStackForDeepPayloads() {
    var validator = CodexJSONDuplicateKeyValidator(deeplyNestedCodexPayload(depth: 5000))
    let isValid = validator.validate()

    #expect(isValid)
  }

  @Test func validBedrockKeyringPayloadIsAccepted() throws {
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let payload = Data(
      #"{"auth_mode":"bedrockApiKey","bedrock_api_key":{"api_key":"bedrock-key","region":"us-east-1"}}"#.utf8
    )
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: { _, _ in payload })

    let snapshot = try storage.snapshot()

    #expect(snapshot.source == storage.keychainSource)
    #expect(snapshot.payload == payload)
    #expect(snapshot.keyringState == .available)
  }

  @Test func fallbackRootCredentialsArePreservedAfterAKeyringSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let keyringOriginal = codexPayload(account: "acct-keyring", token: "key-tok", refresh: "key-ref")
    let fallback = Data(#"{"OPENAI_API_KEY":"sk-fallback"}"#.utf8)
    let slot = CodexKeychainSlot(keyringOriginal)
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: slot.read)
    try writeSecure(fallback, to: storage.authFileURL)
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    let written = try switcher.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 200)
    )

    #expect(written == storage.keychainSource)
    #expect(try Data(contentsOf: storage.authFileURL) == fallback)
    #expect(try CodexCredentialsStore.parse(#require(slot.value)).accountID == "acct-saved")
  }

  @Test func fallbackBackupRefreshesTheTargetBeforeTheKeyringWrite() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let keyringOriginal = codexPayload(account: "acct-keyring", token: "key-tok", refresh: "key-ref")
    let freshTarget = codexPayload(account: "acct-saved", token: "fresh-tok", refresh: "fresh-ref")
    let slot = CodexKeychainSlot(keyringOriginal)
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: slot.read)
    try writeSecure(freshTarget, to: storage.authFileURL)
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    _ = try switcher.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 200)
    )

    let live = try CodexCredentialsStore.parse(#require(slot.value))
    #expect(live.accessToken == "fresh-tok")
    #expect(live.refreshToken == "fresh-ref")
    #expect(!FileManager.default.fileExists(atPath: storage.authFileURL.path))
  }

  func codexPayload(account: String, token: String, refresh: String) -> Data {
    let idToken = "e30.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.sig"
    return Data(
      #"""
      {"last_refresh":"2026-01-01T00:00:00.123456789Z","tokens":{
        "id_token":"\#(idToken)","access_token":"\#(token)",
        "account_id":"\#(account)","refresh_token":"\#(refresh)"
      }}
      """#.utf8
    )
  }
}
