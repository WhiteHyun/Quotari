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

  @Test func requiresARealShortcutModifierForNonFunctionKeys() {
    #expect(
      !DashboardShortcutRecorderButton.hasAllowedModifiers(
        [.numericPad],
        key: .rightArrow
      )
    )
    #expect(
      !DashboardShortcutRecorderButton.hasAllowedModifiers(
        [.shift],
        key: .k
      )
    )
    #expect(
      DashboardShortcutRecorderButton.hasAllowedModifiers(
        [.command, .numericPad],
        key: .rightArrow
      )
    )
    #expect(
      DashboardShortcutRecorderButton.hasAllowedModifiers(
        [.function],
        key: .f1
      )
    )
  }

  @Test func treatsTabAndShiftTabAsFocusTraversal() {
    #expect(DashboardShortcutRecorderButton.isFocusTraversalKey(48, modifiers: []))
    #expect(DashboardShortcutRecorderButton.isFocusTraversalKey(48, modifiers: [.shift]))
    #expect(!DashboardShortcutRecorderButton.isFocusTraversalKey(48, modifiers: [.command]))
  }

  @Test func clearsForwardDeleteWithDeviceFlags() {
    #expect(DashboardShortcutRecorderButton.isClearShortcutKey(51, modifiers: []))
    #expect(DashboardShortcutRecorderButton.isClearShortcutKey(117, modifiers: [.function]))
    #expect(DashboardShortcutRecorderButton.isClearShortcutKey(117, modifiers: [.numericPad]))
    #expect(
      !DashboardShortcutRecorderButton.isClearShortcutKey(
        117,
        modifiers: [.command, .function]
      )
    )
  }

  @Test func endsRecordingWhenTheWindowOrApplicationDeactivates() {
    _ = NSApplication.shared
    let name = KeyboardShortcuts.Name("DashboardShortcutRecorderTests-\(UUID().uuidString)")
    defer {
      KeyboardShortcuts.enable(name)
      KeyboardShortcuts.setShortcut(nil, for: name)
    }
    let button = DashboardShortcutRecorderButton(name: name)
    let window = NSWindow(
      contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = button
    defer { window.orderOut(nil) }

    button.performClick(nil)
    #expect(button.isRecording)

    NotificationCenter.default.post(
      name: NSWindow.didResignKeyNotification,
      object: window
    )

    #expect(!button.isRecording)

    button.performClick(nil)
    #expect(button.isRecording)

    NotificationCenter.default.post(
      name: NSApplication.didResignActiveNotification,
      object: NSApplication.shared
    )

    #expect(!button.isRecording)
  }
}
