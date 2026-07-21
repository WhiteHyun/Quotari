import Observation
import QuotariCore

enum ProviderAccountPopoverAction: Equatable {
  case selectDashboard
  case switchCLI

  init(account: ProviderAccount, isCLIActive: Bool) {
    self = account.credentialSource.isCaptured && !isCLIActive ? .switchCLI : .selectDashboard
  }

  var accessibilityHint: String {
    switch self {
    case .selectDashboard:
      L10n.string("Selects this account and updates the dashboard")
    case .switchCLI:
      L10n.string("Switches the CLI to this saved account")
    }
  }
}

@MainActor
@Observable
final class ProviderAccountPopoverSwitchCoordinator {
  private(set) var switchingAccountID: String?

  func switchCLI(
    to account: ProviderAccount,
    operation: () async -> Bool
  ) async -> Bool {
    guard switchingAccountID == nil else { return false }
    switchingAccountID = account.id
    defer { switchingAccountID = nil }
    return await operation()
  }
}
