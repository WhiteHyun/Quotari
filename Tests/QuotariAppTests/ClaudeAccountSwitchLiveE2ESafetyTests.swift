import Foundation
@testable import QuotariCore
import Testing

struct ClaudeAccountSwitchLiveE2ESafetyTests {
  private let original = ClaudeProfile(
    accountID: "original-account",
    email: "original@example.com"
  )

  @Test
  func unavailableCLIStatusRequiresRestoration() {
    let evidence = ClaudeLiveAuthenticationEvidence(
      credentialProfile: original,
      cliStatus: nil
    )

    #expect(!evidence.matches(original: original))
  }

  @Test
  func restoredDisplaySnapshotCannotHideTheTargetCredential() {
    let target = ClaudeProfile(
      accountID: "target-account",
      email: "target@example.com"
    )
    let evidence = ClaudeLiveAuthenticationEvidence(
      credentialProfile: target,
      cliStatus: ClaudeCLIAuthStatus(loggedIn: true, email: original.email)
    )

    #expect(!evidence.matches(original: original))
  }

  @Test
  func matchingCredentialAndCLIStatusConfirmRestoration() {
    let evidence = ClaudeLiveAuthenticationEvidence(
      credentialProfile: original,
      cliStatus: ClaudeCLIAuthStatus(loggedIn: true, email: original.email)
    )

    #expect(evidence.matches(original: original))
  }

  @Test
  func authStatusDoesNotBlockOnNoisyStandardError() throws {
    let executable = try temporaryExecutable(
      "#!/bin/zsh\n"
        + "(sleep 1; kill -TERM $$) &\nwatchdog=$!\n"
        + "/usr/bin/head -c 1048576 /dev/zero >&2\n"
        + "kill $watchdog 2>/dev/null || true\n"
        + "print '{\"loggedIn\":true,\"email\":\"original@example.com\"}'\n"
    )
    defer { try? FileManager.default.removeItem(at: executable) }

    let status = try claudeAuthStatus(executable: executable)

    #expect(status.loggedIn)
    #expect(status.email == original.email)
  }

  @Test
  func processInspectionErrorsFailClosed() throws {
    let executable = try temporaryExecutable("#!/bin/zsh\nexit 2\n")
    defer { try? FileManager.default.removeItem(at: executable) }

    do {
      try requireQuotariIsNotRunning(pgrepExecutable: executable)
      Issue.record("Expected process inspection to fail closed")
    } catch let ClaudeSwitchLiveE2EError.quotariProcessInspectionFailed(status) {
      #expect(status == 2)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test @MainActor
  func expiredOriginalCredentialUsesProductionRefreshBeforeIdentityLookup() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let source = ProviderCredentialSource.claudeKeychain(service: "test-service")
    let expired = ResolvedClaudeCredentials(
      credentials: ClaudeCredentials(
        accessToken: "expired-access",
        refreshToken: "renewable-refresh",
        expiresAt: now.addingTimeInterval(-60)
      ),
      source: source
    )
    var refreshedAccount: ProviderAccount?
    var reloadedSource: ProviderCredentialSource?

    let refreshed = try await refreshedOriginalClaudeCredentialsIfNeeded(
      expired,
      now: now,
      refresh: { account, _ in refreshedAccount = account },
      reload: { source in
        reloadedSource = source
        return ClaudeCredentials(
          accessToken: "fresh-access",
          refreshToken: "rotated-refresh",
          expiresAt: now.addingTimeInterval(3600)
        )
      }
    )

    #expect(refreshedAccount?.credentialSource == source)
    #expect(reloadedSource == source)
    #expect(refreshed.credentials.accessToken == "fresh-access")
    #expect(refreshed.credentials.refreshToken == "rotated-refresh")
  }

  private func temporaryExecutable(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "QuotariLiveE2ESafety-\(UUID().uuidString)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}
