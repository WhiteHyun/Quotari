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

  static func switchMessage(for activitySnapshot: CLIActivitySnapshot) -> String {
    let key = "Running Claude Code sessions: %@. Quotari will briefly pause them while switching credentials, "
      + "then resume them. They may use the new account on later requests."
    return String.localizedStringWithFormat(
      L10n.string(key: key),
      activitySnapshot.processes.joined(separator: ", ")
    )
  }
}
