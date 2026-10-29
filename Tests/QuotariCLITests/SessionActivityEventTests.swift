import Foundation
import QuotariSharedSnapshot
import Testing

struct SessionActivityEventTests {
  @Test func aFinishedTurnCarriesOnlyTheSessionAndProjectName() throws {
    let event = try #require(SessionActivityEvent(hookPayload: payload("""
    {"hook_event_name": "Stop", "session_id": "abc", "cwd": "/Users/me/src/quotari",
     "transcript_path": "/Users/me/.claude/projects/x.jsonl", "last_assistant_message": "secret answer"}
    """)))

    #expect(event == SessionActivityEvent(kind: .finished, sessionID: "abc", project: "quotari"))
    #expect(event.userInfo == ["kind": "finished", "sessionID": "abc", "project": "quotari"])
    #expect(SessionActivityEvent(userInfo: event.userInfo) == event)
  }

  @Test func onlyPromptsThatWaitOnTheUserNeedInput() {
    let permission = SessionActivityEvent(hookPayload: payload("""
    {"hook_event_name": "Notification", "session_id": "abc", "notification_type": "permission_prompt",
     "message": "Claude needs your permission to use Bash"}
    """))
    let untyped =
      SessionActivityEvent(hookPayload: payload(#"{"hook_event_name": "Notification", "session_id": "abc"}"#))
    let idle = SessionActivityEvent(hookPayload: payload("""
    {"hook_event_name": "Notification", "session_id": "abc", "notification_type": "idle_prompt"}
    """))

    #expect(permission?.kind == .needsInput)
    #expect(permission?.project == nil)
    #expect(untyped?.kind == .needsInput)
    #expect(idle == nil)
  }

  @Test func continuedStopsOtherEventsAndGarbageAreIgnored() {
    #expect(
      SessionActivityEvent(
        hookPayload: payload(#"{"hook_event_name": "Stop", "session_id": "a", "stop_hook_active": true}"#)
      ) ==
        nil
    )
    #expect(
      SessionActivityEvent(
        hookPayload: payload(#"{"hook_event_name": "UserPromptSubmit", "session_id": "a", "prompt": "hi"}"#)
      ) ==
        nil
    )
    #expect(SessionActivityEvent(hookPayload: payload("not json")) == nil)
    #expect(SessionActivityEvent(userInfo: ["kind": "finished"]) == nil)
  }

  private func payload(_ text: String) -> Data {
    Data(text.utf8)
  }
}
