import Foundation

public enum AccountSwitchError: LocalizedError, Sendable {
  case accountNotFound
  case claudeAccountIdentityUnavailable
  case cliActivityCheckFailed(underlying: String)
  case cliStillRunning(processes: [String])
  case concurrentCredentialChange
  case slotReadFailed(underlying: String)
  case backupFailed(underlying: String)
  case writeFailed(underlying: String)
  /// A credential write landed but its follow-up failed, and restoring the
  /// previous credential also failed. Both logins are backed up, but the user
  /// must reconcile the CLI's stores manually.
  case partialSwitch(underlying: String)

  public var errorDescription: String? {
    switch self {
    case .accountNotFound:
      "The saved account could not be found in the registry."
    case .claudeAccountIdentityUnavailable:
      "Quotari couldn’t verify the saved Claude account identity, so it left the CLI login unchanged. "
        + "Scan accounts while this login is active or sign in to it again, then retry."
    case let .cliActivityCheckFailed(underlying):
      "Couldn't verify that the CLI is inactive: \(underlying)"
    case let .cliStillRunning(processes):
      "Quit every active CLI session before switching (\(processes.joined(separator: ", ")))."
    case .concurrentCredentialChange:
      "The CLI login changed during the switch. Quotari stopped before overwriting the newer credentials."
    case let .slotReadFailed(underlying):
      "Couldn't read the CLI's current login before switching: \(underlying)"
    case let .backupFailed(underlying):
      "Couldn't back up the current CLI login before switching: \(underlying)"
    case let .writeFailed(underlying):
      "Couldn't write the account's credentials into the CLI's slot: \(underlying)"
    case let .partialSwitch(underlying):
      "The switch half-applied and couldn't be rolled back (\(underlying)); "
        + "the CLI's credential stores may now differ. Both prior logins are saved in Quotari."
    }
  }
}
