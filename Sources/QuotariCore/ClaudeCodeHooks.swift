import Foundation

/// Adds and removes Quotari's session-activity hooks in Claude Code's
/// `settings.json`, leaving every other entry as it was (ADR 0004).
public enum ClaudeCodeHooks {
  public enum ShapeError: LocalizedError, Equatable {
    case unexpected(String)

    public var errorDescription: String? {
      switch self {
      case let .unexpected(key):
        "Claude Code's settings have an unexpected \"\(key)\" entry, so Quotari left them unchanged."
      }
    }
  }

  static let events = ["Notification", "Stop"]
  /// Every Quotari hook runs the packaged CLI, wherever the app lives.
  static let commandSuffix = "/Contents/Helpers/quotari\" hook"

  public static func command(helper: URL) -> String {
    "\"\(helper.path)\" hook"
  }

  /// The settings with exactly one Quotari hook per event, running `command`.
  public static func installing(command: String, in settings: [String: Any]) throws -> [String: Any] {
    var result = try removing(from: settings)
    var hooks = try dictionary(result["hooks"], key: "hooks") ?? [:]
    for event in events {
      var groups = try array(hooks[event], key: event) ?? []
      groups.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
      hooks[event] = groups
    }
    result["hooks"] = hooks
    return result
  }

  /// The settings without Quotari hooks. Groups and events that held only
  /// Quotari hooks go too.
  public static func removing(from settings: [String: Any]) throws -> [String: Any] {
    guard var hooks = try dictionary(settings["hooks"], key: "hooks") else { return settings }
    var changed = false
    for event in events {
      guard let groups = try array(hooks[event], key: event) else { continue }
      var eventChanged = false
      let kept = groups.compactMap { group -> Any? in
        guard var entry = group as? [String: Any], let handlers = entry["hooks"] as? [Any] else { return group }
        let others = handlers.filter { !isQuotariHandler($0) }
        guard others.count != handlers.count else { return group }
        eventChanged = true
        guard !others.isEmpty else { return nil }
        entry["hooks"] = others
        return entry
      }
      guard eventChanged else { continue }
      changed = true
      hooks[event] = kept.isEmpty ? nil : kept
    }
    guard changed else { return settings }
    var result = settings
    result["hooks"] = hooks.isEmpty ? nil : hooks
    return result
  }

  /// The command of the installed Quotari hooks, or nil unless every event
  /// has one.
  public static func installedCommand(in settings: [String: Any]) -> String? {
    guard let hooks = settings["hooks"] as? [String: Any] else { return nil }
    let commands = events.map { event in
      (hooks[event] as? [Any] ?? [])
        .flatMap { ($0 as? [String: Any])?["hooks"] as? [Any] ?? [] }
        .first(where: isQuotariHandler)
        .flatMap { ($0 as? [String: Any])?["command"] as? String }
    }
    guard let first = commands.first ?? nil, commands.allSatisfy({ $0 == first }) else { return nil }
    return first
  }

  private static func isQuotariHandler(_ handler: Any) -> Bool {
    ((handler as? [String: Any])?["command"] as? String)?.hasSuffix(commandSuffix) == true
  }

  private static func dictionary(_ value: Any?, key: String) throws -> [String: Any]? {
    guard let value else { return nil }
    guard let dictionary = value as? [String: Any] else { throw ShapeError.unexpected(key) }
    return dictionary
  }

  private static func array(_ value: Any?, key: String) throws -> [Any]? {
    guard let value else { return nil }
    guard let array = value as? [Any] else { throw ShapeError.unexpected(key) }
    return array
  }
}

/// Claude Code's user settings file. A missing file reads as empty; a file
/// that isn't a JSON object is never overwritten.
public struct ClaudeCodeSettingsFile: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
  public static func defaultURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let directory = if let configured, !configured.isEmpty {
      URL(fileURLWithPath: configured, isDirectory: true)
    } else {
      home.appendingPathComponent(".claude", isDirectory: true)
    }
    return directory.appendingPathComponent("settings.json")
  }

  public func read() throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
    guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ClaudeCodeHooks.ShapeError.unexpected("settings")
    }
    return settings
  }

  /// Writes through a symlinked settings file, so dotfile setups keep their link.
  public func write(_ settings: [String: Any]) throws {
    let target = url.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
      withJSONObject: settings,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try (data + Data("\n".utf8)).write(to: target, options: .atomic)
  }

  /// Applies `change` and writes only when it changed something.
  public func update(_ change: ([String: Any]) throws -> [String: Any]) throws {
    let current = try read()
    let updated = try change(current)
    guard !NSDictionary(dictionary: current).isEqual(to: updated) else { return }
    try write(updated)
  }
}
