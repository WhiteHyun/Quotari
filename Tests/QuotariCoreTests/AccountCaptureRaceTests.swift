import Foundation
@testable import QuotariCore
import Testing

struct AccountCaptureRaceTests {
  @Test func captureRejectsASlotThatChangedSinceDiscovery() throws {
    let url = try accountCaptureRaceFile(
      #"{"tokens":{"access_token":"a","account_id":"acct-a","refresh_token":"ref-a"}}"#
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let store = accountCaptureRaceStore()
    let service = AccountCaptureService(capturedAccounts: store)
    let discovered = ProviderAccount(
      provider: .codex,
      displayName: "a@example.com",
      detail: "Default",
      credentialSource: .codexAuthFile(path: url.path),
      credentialIdentity: "acct-a"
    )
    try Data(
      #"{"tokens":{"access_token":"b","account_id":"acct-b","refresh_token":"ref-b"}}"#.utf8
    ).write(to: url)

    #expect(throws: AccountCaptureError.credentialChanged) {
      try service.capture(discovered, now: Date(timeIntervalSince1970: 1000))
    }
    #expect(store.load().isEmpty)
  }

  @Test func captureNeverLetsAStaleSlotClobberAFresherSavedPair() throws {
    let store = accountCaptureRaceStore()
    let service = AccountCaptureService(capturedAccounts: store)
    let freshJWT = accountCaptureRaceJWT(exp: 100_000)
    let staleJWT = accountCaptureRaceJWT(exp: 1000)
    let freshURL = try accountCaptureRaceFile(
      #"{"tokens":{"access_token":"\#(freshJWT)","account_id":"acct-1","refresh_token":"ref-new"}}"#
    )
    let staleURL = try accountCaptureRaceFile(
      #"{"tokens":{"access_token":"\#(staleJWT)","account_id":"acct-1","refresh_token":"ref-old"}}"#
    )
    defer {
      try? FileManager.default.removeItem(at: freshURL)
      try? FileManager.default.removeItem(at: staleURL)
    }
    _ = try service.capture(accountCaptureRaceAccount(url: freshURL), now: Date(timeIntervalSince1970: 1000))
    _ = try service.capture(accountCaptureRaceAccount(url: staleURL), now: Date(timeIntervalSince1970: 1060))

    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == freshJWT)
    #expect(saved.refreshToken == "ref-new")
  }
}

private func accountCaptureRaceStore() -> CapturedAccountStore {
  CapturedAccountStore(
    keychain: InMemoryKeychain().store,
    service: "Test-Capture-Race-\(UUID().uuidString)"
  )
}

private func accountCaptureRaceFile(_ contents: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("codex-auth-race-\(UUID().uuidString).json")
  try Data(contents.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  return url
}

private func accountCaptureRaceAccount(url: URL) -> ProviderAccount {
  ProviderAccount(
    provider: .codex,
    displayName: "Codex",
    detail: "Duplicate",
    credentialSource: .codexAuthFile(path: url.path)
  )
}

private func accountCaptureRaceJWT(exp: TimeInterval) -> String {
  func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
  let payload = base64URL((try? JSONSerialization.data(withJSONObject: ["exp": exp])) ?? Data())
  return "\(header).\(payload).sig"
}
