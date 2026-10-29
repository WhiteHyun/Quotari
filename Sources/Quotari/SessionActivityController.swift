import AppKit
import Observation
import QuotariCore
import QuotariSharedSnapshot

/// Running CLI sessions, and the opt-in Claude Code hooks that report when a
/// session needs input or finishes (ADR 0004).
@MainActor
@Observable
final class SessionActivityController {
  private(set) var runningCounts: [UsageProvider: Int] = [:]
  private(set) var hooksInstalled = false
  private(set) var hookError: String?

  /// Nil when the app runs without its packaged CLI, as in source builds.
  @ObservationIgnored let hookCommand: String?
  @ObservationIgnored let settingsFile: ClaudeCodeSettingsFile
  @ObservationIgnored var countProbe: @Sendable (UsageProvider) -> Int
  @ObservationIgnored var onEvent: ((SessionActivityEvent) -> Void)?
  @ObservationIgnored private var observer: (any NSObjectProtocol)?

  init(
    hookCommand: String? = SessionActivityController.packagedHookCommand(),
    settingsFile: ClaudeCodeSettingsFile = ClaudeCodeSettingsFile(url: ClaudeCodeSettingsFile.defaultURL()),
    countProbe: @escaping @Sendable (UsageProvider) -> Int = SessionActivityController.runningSessionCount
  ) {
    self.hookCommand = hookCommand
    self.settingsFile = settingsFile
    self.countProbe = countProbe
  }

  nonisolated static func packagedHookCommand(bundle: Bundle = .main) -> String? {
    let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/quotari")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
    return ClaudeCodeHooks.command(helper: helper)
  }

  nonisolated static func runningSessionCount(_ provider: UsageProvider) -> Int {
    (try? CLIActivityDetector().activeProcessRecords(for: provider).count) ?? 0
  }

  /// Counts processes off the main actor; `ps` can take a moment.
  func refreshRunningCounts(for providers: [UsageProvider]) async {
    let probe = countProbe
    let counts = await Task.detached {
      Dictionary(uniqueKeysWithValues: providers.map { ($0, probe($0)) })
    }.value
    if counts != runningCounts {
      runningCounts = counts
    }
  }

  /// Reads whether the hooks are installed, and points them at this copy of
  /// the app if it moved since they were installed.
  func syncHooks() {
    guard let settings = try? settingsFile.read() else {
      hooksInstalled = false
      return
    }
    let installed = ClaudeCodeHooks.installedCommand(in: settings)
    hooksInstalled = installed != nil
    if let installed, let hookCommand, installed != hookCommand {
      try? settingsFile.update { try ClaudeCodeHooks.installing(command: hookCommand, in: $0) }
    }
  }

  var hooksEnabled: Bool {
    get { hooksInstalled }
    set { setHooksInstalled(newValue) }
  }

  func setHooksInstalled(_ install: Bool) {
    hookError = nil
    do {
      if install {
        guard let hookCommand else { return }
        try settingsFile.update { try ClaudeCodeHooks.installing(command: hookCommand, in: $0) }
      } else {
        try settingsFile.update { try ClaudeCodeHooks.removing(from: $0) }
      }
      hooksInstalled = install
    } catch {
      hookError = error.localizedDescription
    }
  }

  /// Passes relayed events to `onEvent` while the hooks are installed.
  func startListening() {
    guard observer == nil else { return }
    observer = DistributedNotificationCenter.default().addObserver(
      forName: SessionActivityEvent.notificationName,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let event = SessionActivityEvent(userInfo: notification.userInfo)
      MainActor.assumeIsolated {
        self?.receive(event)
      }
    }
  }

  func receive(_ event: SessionActivityEvent?) {
    guard hooksInstalled, let event else { return }
    onEvent?(event)
  }
}
