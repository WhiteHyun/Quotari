import CustomDump
import Foundation
@testable import QuotariCore
import Testing

struct ClaudeAccountSwitchLiveE2ESafetyTests {
  private let original = ClaudeProfile(
    accountID: "original-account",
    email: "original@example.com",
    organizationID: "original-organization"
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
  func sameAccountUUIDInAnotherOrganizationRequiresRestoration() {
    let evidence = ClaudeLiveAuthenticationEvidence(
      credentialProfile: ClaudeProfile(
        accountID: original.accountID,
        email: original.email,
        organizationID: "other-organization"
      ),
      cliStatus: ClaudeCLIAuthStatus(loggedIn: true, email: original.email)
    )

    #expect(!evidence.matches(original: original))
  }

  @Test
  func missingOrganizationUUIDRequiresRestoration() {
    let evidence = ClaudeLiveAuthenticationEvidence(
      credentialProfile: ClaudeProfile(
        accountID: original.accountID,
        email: original.email
      ),
      cliStatus: ClaudeCLIAuthStatus(loggedIn: true, email: original.email)
    )

    #expect(!evidence.matches(original: original))
  }
}

extension ClaudeAccountSwitchLiveE2ESafetyTests {
  @Test
  func targetRequiresMatchingStrongStoredAndClaudeCodeIdentities() throws {
    let target = try targetAccount(
      storedOrganizationID: "target-organization",
      stateOrganizationID: "target-organization"
    )

    let identity = try requiredStrongTargetIdentity(for: target)

    expectNoDifference(
      identity,
      ClaudeAccountIdentity(
        accountID: "target-account",
        email: "target@example.com",
        organizationID: "target-organization"
      )
    )
  }

  @Test
  func targetWithSameAccountUUIDInAnotherOrganizationFailsClosed() throws {
    let target = try targetAccount(
      storedOrganizationID: "stored-organization",
      stateOrganizationID: "other-organization"
    )

    do {
      _ = try requiredStrongTargetIdentity(for: target)
      Issue.record("Expected a conflicting target organization to fail closed")
    } catch ClaudeSwitchLiveE2EError.targetIdentityUnavailable {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func targetWithoutOrganizationUUIDFailsClosed() throws {
    let target = try targetAccount(
      storedOrganizationID: nil,
      stateOrganizationID: nil
    )

    do {
      _ = try requiredStrongTargetIdentity(for: target)
      Issue.record("Expected a weak target identity to fail closed")
    } catch ClaudeSwitchLiveE2EError.targetIdentityUnavailable {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

extension ClaudeAccountSwitchLiveE2ESafetyTests {
  @Test
  func cleanupRemovesOnlyAnExactStrongOriginalBackup() throws {
    let fixture = try cleanupFixture(identity: ClaudeAccountIdentity(
      accountID: original.accountID,
      organizationID: original.organizationID
    ))

    try removeTestCreatedOriginalBackup(
      from: fixture.registry,
      preserving: [],
      original: fixture.original
    )

    #expect(fixture.registry.account(id: fixture.backupID) == nil)
  }

  @Test
  func cleanupPreservesSameAccountUUIDInAnotherOrganization() throws {
    let fixture = try cleanupFixture(identity: ClaudeAccountIdentity(
      accountID: original.accountID,
      organizationID: "other-organization"
    ))

    try removeTestCreatedOriginalBackup(
      from: fixture.registry,
      preserving: [],
      original: fixture.original
    )

    #expect(fixture.registry.account(id: fixture.backupID) != nil)
  }

  @Test
  func cleanupPreservesBackupWithoutOrganizationUUID() throws {
    let fixture = try cleanupFixture(identity: ClaudeAccountIdentity(
      accountID: original.accountID
    ))

    try removeTestCreatedOriginalBackup(
      from: fixture.registry,
      preserving: [],
      original: fixture.original
    )

    #expect(fixture.registry.account(id: fixture.backupID) != nil)
  }
}

extension ClaudeAccountSwitchLiveE2ESafetyTests {
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
}

private extension ClaudeAccountSwitchLiveE2ESafetyTests {
  private func temporaryExecutable(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "QuotariLiveE2ESafety-\(UUID().uuidString)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func targetAccount(
    storedOrganizationID: String?,
    stateOrganizationID: String?
  ) throws -> CapturedAccount {
    var oauthAccount: [String: Any] = [
      "accountUuid": "target-account",
      "emailAddress": "target@example.com",
    ]
    if let stateOrganizationID {
      oauthAccount["organizationUuid"] = stateOrganizationID
    }
    return try CapturedAccount(
      id: "claude:target",
      provider: .claude,
      displayName: "Target",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: "test-service"),
      payload: Data(),
      claudeOAuthAccount: JSONSerialization.data(withJSONObject: oauthAccount),
      claudeAccountIdentity: ClaudeAccountIdentity(
        accountID: "target-account",
        email: "target@example.com",
        organizationID: storedOrganizationID
      )
    )
  }

  private func cleanupFixture(
    identity: ClaudeAccountIdentity
  ) throws -> ClaudeSwitchCleanupFixture {
    let payload = Data(
      #"{"claudeAiOauth":{"accessToken":"test-access","refreshToken":"test-refresh"}}"#.utf8
    )
    let credentialIdentity = try #require(
      ProviderCredentialIdentity.key(provider: .claude, payload: payload)
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let backupID = "claude:test-backup"
    try registry.save(CapturedAccount(
      id: backupID,
      provider: .claude,
      displayName: "Original backup",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: "test-service"),
      payload: payload,
      claudeAccountIdentity: identity
    ))
    return ClaudeSwitchCleanupFixture(
      registry: registry,
      backupID: backupID,
      original: ClaudeOriginalAccountState(identity: credentialIdentity, profile: original)
    )
  }
}

private struct ClaudeSwitchCleanupFixture {
  var registry: CapturedAccountStore
  var backupID: String
  var original: ClaudeOriginalAccountState
}
