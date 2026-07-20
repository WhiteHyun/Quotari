import AppKit
import KeyboardShortcuts
@testable import Quotari
import Testing

@MainActor
struct DashboardShortcutRecorderTests {
  @Test func reflectsTheStoredShortcutWithoutLoadingDependencyResources() {
    let name = KeyboardShortcuts.Name("DashboardShortcutRecorderTests-\(UUID().uuidString)")
    defer { KeyboardShortcuts.setShortcut(nil, for: name) }
    let button = DashboardShortcutRecorderButton(name: name)

    #expect(button.title == "Record Shortcut")

    let shortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
    KeyboardShortcuts.setShortcut(shortcut, for: name)
    button.refreshTitle()

    #expect(button.title == "\(shortcut)")
  }
}
