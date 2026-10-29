import Foundation
@testable import Quotari
@testable import QuotariCore
import QuotariSharedSnapshot
import Testing

@MainActor
struct SessionActivityControllerTests {
  private let settingsURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("claude-settings-\(UUID().uuidString).json")
  private let command = ClaudeCodeHooks
    .command(helper: URL(fileURLWithPath: "/Applications/Quotari.app/Contents/Helpers/quotari"))

  @Test func theToggleInstallsAndRemovesTheHooksAroundTheUsersSettings() throws {
    defer { try? FileManager.default.removeItem(at: settingsURL) }
    try Data(#"{"model": "opus"}"#.utf8).write(to: settingsURL)
    let controller = makeController(hookCommand: command)

    controller.hooksEnabled = true
    #expect(controller.hooksInstalled)
    #expect(try ClaudeCodeHooks.installedCommand(in: ClaudeCodeSettingsFile(url: settingsURL).read()) == command)

    controller.hooksEnabled = false
    #expect(!controller.hooksInstalled)
    #expect(try ClaudeCodeSettingsFile(url: settingsURL).read() as NSDictionary == ["model": "opus"])
  }

  @Test func syncFindsInstalledHooksAndRepointsThemAfterTheAppMoved() throws {
    defer { try? FileManager.default.removeItem(at: settingsURL) }
    let old = ClaudeCodeHooks
      .command(helper: URL(fileURLWithPath: "/Users/me/Downloads/Quotari.app/Contents/Helpers/quotari"))
    try ClaudeCodeSettingsFile(url: settingsURL).write(ClaudeCodeHooks.installing(command: old, in: [:]))
    let controller = makeController(hookCommand: command)

    controller.syncHooks()

    #expect(controller.hooksInstalled)
    #expect(try ClaudeCodeHooks.installedCommand(in: ClaudeCodeSettingsFile(url: settingsURL).read()) == command)
  }

  @Test func aBrokenSettingsFileReportsAnErrorAndStaysUntouched() throws {
    defer { try? FileManager.default.removeItem(at: settingsURL) }
    try Data("{".utf8).write(to: settingsURL)
    let controller = makeController(hookCommand: command)

    controller.hooksEnabled = true

    #expect(!controller.hooksInstalled)
    #expect(controller.hookError != nil)
    #expect(try String(contentsOf: settingsURL, encoding: .utf8) == "{")
  }

  @Test func eventsReachTheHandlerOnlyWhileTheHooksAreInstalled() {
    defer { try? FileManager.default.removeItem(at: settingsURL) }
    let controller = makeController(hookCommand: command)
    var received: [SessionActivityEvent] = []
    controller.onEvent = { received.append($0) }
    let event = SessionActivityEvent(kind: .finished, sessionID: "s1", project: "quotari")

    controller.receive(event)
    controller.hooksEnabled = true
    controller.receive(event)
    controller.receive(nil)

    #expect(received == [event])
  }

  @Test func runningCountsComeFromTheProbe() async {
    let controller = makeController(hookCommand: nil) { $0 == .claude ? 2 : 0 }

    await controller.refreshRunningCounts(for: [.claude, .codex])

    #expect(controller.runningCounts == [.claude: 2, .codex: 0])
  }

  @Test func aDeliveredAlertNamesTheProjectAndFollowsTheNotificationSwitch() async throws {
    let defaults = try #require(UserDefaults(suiteName: "session-alerts-\(UUID().uuidString)"))
    let center = QuotaNotificationCenterStub(status: .authorized)
    let notifications = QuotaNotificationController(center: center, defaults: defaults)
    let event = SessionActivityEvent(kind: .needsInput, sessionID: "s1", project: "quotari")

    await notifications.deliverSessionActivityAlert(event)
    #expect(center.attemptedSessionAlerts.isEmpty)

    _ = await notifications.setNotificationsEnabled(true)
    await notifications.deliverSessionActivityAlert(event)
    #expect(center.attemptedSessionAlerts == [SessionActivityAlert(event: event)])
    #expect(center.attemptedSessionAlerts.first?.requestID == "quotari.session.s1")
  }

  private func makeController(
    hookCommand: String?,
    countProbe: @escaping @Sendable (UsageProvider) -> Int = { _ in 0 }
  ) -> SessionActivityController {
    SessionActivityController(
      hookCommand: hookCommand,
      settingsFile: ClaudeCodeSettingsFile(url: settingsURL),
      countProbe: countProbe
    )
  }
}
