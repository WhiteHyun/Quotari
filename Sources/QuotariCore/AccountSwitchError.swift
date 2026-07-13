import Foundation

public enum AccountSwitchError: LocalizedError, Sendable {
  case accountNotFound
  case slotReadFailed(underlying: String)
  case backupFailed(underlying: String)
  case writeFailed(underlying: String)
  /// The keychain was switched but the credentials-file write failed AND the
  /// keychain rollback also failed: the two Claude stores now disagree. Both
  /// logins are still backed up, but the user must reconcile.
  case partialSwitch(underlying: String)

  public var errorDescription: String? {
    switch self {
    case .accountNotFound:
      "The saved account could not be found in the registry."
    case let .slotReadFailed(underlying):
      "Couldn't read the CLI's current login before switching: \(underlying)"
    case let .backupFailed(underlying):
      "Couldn't back up the current CLI login before switching: \(underlying)"
    case let .writeFailed(underlying):
      "Couldn't write the account's credentials into the CLI's slot: \(underlying)"
    case let .partialSwitch(underlying):
      "The switch half-applied and couldn't be rolled back (\(underlying)); "
        + "Claude's keychain and credentials file now differ. Both prior logins are saved in Quotari."
    }
  }
}
