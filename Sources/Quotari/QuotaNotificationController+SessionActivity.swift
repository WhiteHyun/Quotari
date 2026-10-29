import Foundation
import QuotariSharedSnapshot

/// A Claude Code session that needs input or finished.
struct SessionActivityAlert: Equatable, Sendable {
  var event: SessionActivityEvent

  /// One notification per session: a newer event replaces the older one.
  var requestID: String {
    "quotari.session.\(event.sessionID)"
  }
}

extension QuotaNotificationController {
  func deliverSessionActivityAlert(_ event: SessionActivityEvent) async {
    guard preferences.isEnabled else { return }
    do {
      try await center.addSessionActivityAlert(SessionActivityAlert(event: event))
    } catch {
      lastError = error.localizedDescription
    }
  }
}
