import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ClaudeLoginSlotRecoveryTests {
  @Test func failedKeychainLoginLeavesADifferentCredentialsFileUntouched() async throws {
    let context = try makeClaudeLoginContext()
    let filePayload = claudePayload(
      accessToken: "saved-other-access",
      refreshToken: "saved-other-refresh"
    )
    try FileManager.default.createDirectory(
      at: context.credentialFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try filePayload.write(to: context.credentialFileURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: context.credentialFileURL.path
    )
    let interruptedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      credentialMutation?()
      context.liveCredential.value = interruptedPayload
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let restoredKeychain = try ClaudeCredentialsStore.parse(#require(context.liveCredential.value))
    #expect(restoredKeychain.accessToken == "current-access")
    #expect(try Data(contentsOf: context.credentialFileURL) == filePayload)
  }
}
