import Foundation
@testable import QuotariCore
import Testing

struct ClaudeCodeHooksTests {
  private let command = ClaudeCodeHooks
    .command(helper: URL(fileURLWithPath: "/Applications/Quotari.app/Contents/Helpers/quotari"))

  /// A settings file with the user's own hooks on the same events.
  private func existingSettings() throws -> [String: Any] {
    try json("""
    {
      "permissions": {"allow": ["Bash(git status)"]},
      "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"},
      "hooks": {
        "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}],
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh"}]}],
        "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
      }
    }
    """)
  }

  @Test func installingKeepsOtherEntriesAndIsIdempotent() throws {
    let original = try existingSettings()

    let once = try ClaudeCodeHooks.installing(command: command, in: original)
    let twice = try ClaudeCodeHooks.installing(command: command, in: once)

    #expect(NSDictionary(dictionary: once).isEqual(to: twice))
    #expect(ClaudeCodeHooks.installedCommand(in: once) == command)
    let hooks = try #require(once["hooks"] as? [String: Any])
    #expect((hooks["Notification"] as? [Any])?.count == 2)
    #expect((hooks["Stop"] as? [Any])?.count == 2)
    #expect(try NSArray(array: hooks["PreToolUse"] as? [Any] ?? [])
      .isEqual(to: #require(original["hooks"] as? [String: Any])["PreToolUse"] as? [Any] ?? []))
    #expect(NSDictionary(dictionary: once["permissions"] as? [String: Any] ?? [:])
      .isEqual(to: original["permissions"] as? [String: Any] ?? [:]))
  }

  @Test func removingRestoresTheOriginalAndIsIdempotent() throws {
    let original = try existingSettings()
    let installed = try ClaudeCodeHooks.installing(command: command, in: original)

    let removed = try ClaudeCodeHooks.removing(from: installed)

    #expect(NSDictionary(dictionary: removed).isEqual(to: original))
    #expect(try NSDictionary(dictionary: ClaudeCodeHooks.removing(from: removed)).isEqual(to: original))
    #expect(ClaudeCodeHooks.installedCommand(in: removed) == nil)
  }

  @Test func onlyQuotariHooksLeaveAndEmptiedEventsGoToo() throws {
    let empty = try ClaudeCodeHooks.removing(from: ClaudeCodeHooks.installing(command: command, in: [:]))
    #expect(empty.isEmpty)

    // A group the user extended keeps the user's handler.
    let shared = try json("""
    {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"},
      {"type": "command", "command": "\\"/Old/Quotari.app/Contents/Helpers/quotari\\" hook"}]}], "SessionStart": []}}
    """)
    let cleaned = try ClaudeCodeHooks.removing(from: shared)
    let stop = try #require((cleaned["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
    #expect((stop.first?["hooks"] as? [Any])?.count == 1)
    #expect((cleaned["hooks"] as? [String: Any])?["SessionStart"] != nil)
  }

  @Test func reinstallingAfterTheAppMovedReplacesTheOldCommand() throws {
    let old = ClaudeCodeHooks
      .command(helper: URL(fileURLWithPath: "/Users/me/Downloads/Quotari.app/Contents/Helpers/quotari"))
    let moved = try ClaudeCodeHooks.installing(command: command, in: ClaudeCodeHooks.installing(command: old, in: [:]))

    #expect(ClaudeCodeHooks.installedCommand(in: moved) == command)
    #expect(((moved["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1)
  }

  @Test func anUnexpectedHooksEntryIsLeftAlone() throws {
    let odd = try json(#"{"hooks": {"Stop": "say done"}}"#)

    #expect(throws: ClaudeCodeHooks.ShapeError.unexpected("Stop")) {
      try ClaudeCodeHooks.installing(command: command, in: odd)
    }
  }

  private func json(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }
}

struct ClaudeCodeSettingsFileTests {
  @Test func updatesWriteThroughASymlinkAndSkipNoOps() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-settings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("dotfiles-settings.json")
    let link = directory.appendingPathComponent("settings.json")
    try Data(#"{"model": "opus"}"#.utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let file = ClaudeCodeSettingsFile(url: link)
    let command = ClaudeCodeHooks
      .command(helper: URL(fileURLWithPath: "/Applications/Quotari.app/Contents/Helpers/quotari"))

    try file.update { try ClaudeCodeHooks.installing(command: command, in: $0) }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(try ClaudeCodeHooks.installedCommand(in: file.read()) == command)
    #expect(try file.read()["model"] as? String == "opus")

    try FileManager.default.removeItem(at: target)
    try file.update { try ClaudeCodeHooks.removing(from: $0) }
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }

  @Test func aFileThatIsNotAnObjectIsNeverOverwritten() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("[1, 2".utf8).write(to: url)
    let file = ClaudeCodeSettingsFile(url: url)

    #expect(throws: (any Error).self) {
      try file.update { try ClaudeCodeHooks.installing(command: "x", in: $0) }
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == "[1, 2")
  }

  @Test func theConfigDirectoryOverridesTheHomeLocation() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(ClaudeCodeSettingsFile.defaultURL(environment: [:], home: home).path == "/Users/me/.claude/settings.json")
    #expect(ClaudeCodeSettingsFile.defaultURL(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"], home: home)
      .path == "/tmp/cc/settings.json")
  }
}
