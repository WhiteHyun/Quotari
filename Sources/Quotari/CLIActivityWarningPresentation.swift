import Foundation
import QuotariCore

enum CLIActivityWarningPresentation {
  static func message(for activitySnapshot: CLIActivitySnapshot) -> String {
    let key = "Running Claude Code sessions: %@. If you continue, those sessions may use the new account "
      + "on later requests. Quotari will leave them open."
    return String.localizedStringWithFormat(
      L10n.string(key: key),
      activitySnapshot.processes.joined(separator: ", ")
    )
  }

  static func switchBlockedMessage(for activitySnapshot: CLIActivitySnapshot) -> String {
    let key = "Running Claude Code sessions: %@. Quit all of them, then try again. "
      + "Quotari will not switch the CLI account while a session is running."
    return String.localizedStringWithFormat(
      L10n.string(key: key),
      activitySnapshot.processes.joined(separator: ", ")
    )
  }
}
