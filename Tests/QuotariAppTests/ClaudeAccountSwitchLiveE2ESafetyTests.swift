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
}
