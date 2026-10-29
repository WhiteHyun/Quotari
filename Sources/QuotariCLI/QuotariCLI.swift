import Foundation
import QuotariSharedSnapshot

@main
enum QuotariCLI {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["hook"] {
      relayHookEvent()
    }
    let output = QuotariCommand.run(arguments, file: SharedUsageSnapshotFile(), now: Date())
    FileHandle.standardOutput.write(Data(output.standardOutput.utf8))
    FileHandle.standardError.write(Data(output.standardError.utf8))
    exit(output.exitCode)
  }

  /// Runs as a Claude Code hook that Quotari installed on opt-in. It passes the
  /// event to the running app and always exits cleanly so it never disturbs
  /// the session; with the app closed, the event is dropped.
  private static func relayHookEvent() -> Never {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    if let event = SessionActivityEvent(hookPayload: payload) {
      DistributedNotificationCenter.default().postNotificationName(
        SessionActivityEvent.notificationName,
        object: nil,
        userInfo: event.userInfo,
        deliverImmediately: true
      )
    }
    exit(0)
  }
}
