import Foundation

/// A Claude Code session event that `quotari hook` relays to the running app.
/// Only these fields leave the hook; prompt, response, and path text in the
/// payload are discarded on receipt (ADR 0004).
public struct SessionActivityEvent: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case needsInput
    case finished
  }

  /// The distributed notification that carries an event to the app.
  public static let notificationName = Notification.Name("com.whitehyun.quotari.sessionActivity")

  /// Notifications that wait on the user. Idle reminders follow a finished
  /// turn, so they would repeat its alert.
  static let inputNotificationTypes: Set = ["permission_prompt", "elicitation_dialog"]

  public var kind: Kind
  public var sessionID: String
  /// The session's working-directory name, never its full path.
  public var project: String?

  public init(kind: Kind, sessionID: String, project: String?) {
    self.kind = kind
    self.sessionID = sessionID
    self.project = project
  }

  /// Reads a Claude Code hook payload, or nil for events Quotari doesn't
  /// alert on.
  public init?(hookPayload data: Data) {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sessionID = payload["session_id"] as? String
    else { return nil }
    switch payload["hook_event_name"] as? String {
    case "Stop":
      // A stop hook asked Claude to keep going, so the turn hasn't finished.
      guard payload["stop_hook_active"] as? Bool != true else { return nil }
      kind = .finished
    case "Notification":
      // Older Claude Code versions send no type; their notifications all wait
      // on the user.
      if let type = payload["notification_type"] as? String,
         !Self.inputNotificationTypes.contains(type) {
        return nil
      }
      kind = .needsInput
    default:
      return nil
    }
    self.sessionID = sessionID
    let directory = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    project = directory?.isEmpty == false && directory != "/" ? directory : nil
  }

  public var userInfo: [String: String] {
    var info = ["kind": kind.rawValue, "sessionID": sessionID]
    info["project"] = project
    return info
  }

  public init?(userInfo: [AnyHashable: Any]?) {
    guard let userInfo,
          let kind = (userInfo["kind"] as? String).flatMap(Kind.init(rawValue:)),
          let sessionID = userInfo["sessionID"] as? String
    else { return nil }
    self.init(kind: kind, sessionID: sessionID, project: userInfo["project"] as? String)
  }
}
