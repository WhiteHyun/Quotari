@testable import Quotari
@testable import QuotariCore
import Testing

struct ProviderAccountPopoverTests {
  @Test func tappingAnInactiveSavedAccountSwitchesTheCLI() {
    let account = popoverAccount(source: .quotariRegistry(id: "claude:saved"))

    #expect(ProviderAccountPopoverAction(account: account, isCLIActive: false) == .switchCLI)
  }

  @Test func tappingTheActiveAccountOnlySelectsTheDashboard() {
    let account = popoverAccount(source: .claudeKeychain(service: "Claude Code-credentials"))

    #expect(ProviderAccountPopoverAction(account: account, isCLIActive: true) == .selectDashboard)
  }

  @Test func tappingANonSavedAccountOnlySelectsTheDashboard() {
    let account = popoverAccount(source: .claudeCredentialsFile(path: "/tmp/.credentials.json"))

    #expect(ProviderAccountPopoverAction(account: account, isCLIActive: false) == .selectDashboard)
  }

  @MainActor
  @Test func switchingCoordinatesInFlightReentrySuccessAndFailure() async {
    let coordinator = ProviderAccountPopoverSwitchCoordinator()
    let firstAccount = popoverAccount(source: .quotariRegistry(id: "claude:first"))
    let secondAccount = popoverAccount(source: .quotariRegistry(id: "claude:second"))
    let gate = PopoverSwitchGate()

    let firstSwitch = Task {
      await coordinator.switchCLI(to: firstAccount) {
        await gate.waitForResult()
      }
    }
    for _ in 0 ..< 100 {
      if gate.isWaiting {
        break
      }
      await Task.yield()
    }

    #expect(gate.isWaiting)
    #expect(coordinator.switchingAccountID == firstAccount.id)

    var reentryOperationCount = 0
    let reentryShouldDismiss = await coordinator.switchCLI(to: secondAccount) {
      reentryOperationCount += 1
      return true
    }

    #expect(!reentryShouldDismiss)
    #expect(reentryOperationCount == 0)
    #expect(coordinator.switchingAccountID == firstAccount.id)

    gate.resume(returning: true)
    let successShouldDismiss = await firstSwitch.value

    #expect(successShouldDismiss)
    #expect(coordinator.switchingAccountID == nil)

    let failureShouldDismiss = await coordinator.switchCLI(to: secondAccount) {
      false
    }

    #expect(!failureShouldDismiss)
    #expect(coordinator.switchingAccountID == nil)
  }

  @Test func activeSessionConfirmationBlocksSwitchingUntilRetry() {
    let account = popoverAccount(source: .quotariRegistry(id: "claude:saved"))
    let confirmation = ProviderAccountPopoverConfirmation.switchBlocked(
      account,
      CLIActivitySnapshot(provider: .claude, processes: ["claude (PID 42)"])
    )

    #expect(confirmation.title == "Quit Claude Code before switching")
    #expect(confirmation.confirmButtonTitle == "Try Again")
    #expect(!confirmation.dismissesBeforeConfirming)
    #expect(confirmation.message.contains("claude (PID 42)"))
    #expect(!confirmation.message.contains("pause"))
    #expect(!confirmation.message.contains("resume"))
  }
}

@MainActor
private final class PopoverSwitchGate {
  private(set) var isWaiting = false
  private var continuation: CheckedContinuation<Bool, Never>?

  func waitForResult() async -> Bool {
    await withCheckedContinuation { continuation in
      isWaiting = true
      self.continuation = continuation
    }
  }

  func resume(returning result: Bool) {
    isWaiting = false
    continuation?.resume(returning: result)
    continuation = nil
  }
}

private func popoverAccount(source: ProviderCredentialSource) -> ProviderAccount {
  ProviderAccount(
    provider: .claude,
    displayName: "Claude",
    detail: nil,
    credentialSource: source
  )
}
