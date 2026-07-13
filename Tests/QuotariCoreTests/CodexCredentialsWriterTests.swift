import Foundation
@testable import QuotariCore
import Testing

struct CodexCredentialsWriterTests {
  @Test func mergeRotatesTokensAndPreservesSiblings() throws {
    let payload = Data(#"""
    {"tokens": {"access_token": "old-tok", "refresh_token": "old-ref",
                "id_token": "old-id", "account_id": "acct-1"}}
    """#.utf8)
    let grant = CodexTokenGrant(accessToken: "new-tok", refreshToken: "new-ref", idToken: "new-id")

    let merged = try CodexCredentialsWriter().merge(grant, replacing: "old-tok", into: payload)

    let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
    let tokens = root?["tokens"] as? [String: Any]
    #expect(tokens?["access_token"] as? String == "new-tok")
    #expect(tokens?["refresh_token"] as? String == "new-ref")
    #expect(tokens?["id_token"] as? String == "new-id")
    #expect(tokens?["account_id"] as? String == "acct-1")
  }

  @Test func mergeWithoutRotatedFieldsKeepsTheStoredOnes() throws {
    let payload = codexAuthPayload(accessToken: "old-tok", refreshToken: "old-ref")

    let merged = try CodexCredentialsWriter()
      .merge(CodexTokenGrant(accessToken: "new-tok"), replacing: "old-tok", into: payload)

    let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
    let tokens = root?["tokens"] as? [String: Any]
    #expect(tokens?["access_token"] as? String == "new-tok")
    #expect(tokens?["refresh_token"] as? String == "old-ref")
  }

  @Test func mergeRefusesAStaleSource() {
    let payload = codexAuthPayload(accessToken: "someone-elses-tok")
    #expect(throws: CodexCredentialPersistError.self) {
      _ = try CodexCredentialsWriter()
        .merge(CodexTokenGrant(accessToken: "new-tok"), replacing: "old-tok", into: payload)
    }
  }

  @Test func persistRefusesWhenThePayloadRotatedConcurrently() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "Test-Writer-\(UUID().uuidString)")
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Saved",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: "/tmp/old.json"),
      payload: codexAuthPayload(accessToken: "recaptured-tok", refreshToken: "recaptured-ref")
    ))

    // A merge based on a pair the registry no longer holds must not land.
    #expect(throws: CodexCredentialPersistError.self) {
      try CodexCredentialsWriter(capturedAccounts: store).persist(
        CodexTokenGrant(accessToken: "new-tok"),
        replacing: "old-tok",
        toRegistryAccount: "codex:acct-1"
      )
    }

    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == "recaptured-tok")
    #expect(saved.refreshToken == "recaptured-ref")
  }

  @Test func persistWritesTheMergedPayloadBackToTheRegistry() throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "Test-Writer-\(UUID().uuidString)")
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Saved",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: "/tmp/old.json"),
      payload: codexAuthPayload(accessToken: "old-tok", refreshToken: "old-ref")
    ))

    try CodexCredentialsWriter(capturedAccounts: store).persist(
      CodexTokenGrant(accessToken: "new-tok", refreshToken: "new-ref"),
      replacing: "old-tok",
      toRegistryAccount: "codex:acct-1"
    )

    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == "new-tok")
    #expect(saved.refreshToken == "new-ref")
    #expect(saved.accountID == "acct-1")
  }
}
