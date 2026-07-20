import AppKit
import KeyboardShortcuts
import SwiftUI

struct DashboardShortcutRecorder: NSViewRepresentable {
  func makeNSView(context: Context) -> DashboardShortcutRecorderButton {
    DashboardShortcutRecorderButton(name: .toggleDashboard)
  }

  func updateNSView(_ nsView: DashboardShortcutRecorderButton, context: Context) {
    nsView.refreshTitle()
  }
}

@MainActor
final class DashboardShortcutRecorderButton: NSButton {
  private let shortcutName: KeyboardShortcuts.Name
  private var eventMonitor: Any?
  private var deactivationObservers: [NSObjectProtocol] = []
  private(set) var isRecording = false

  init(name: KeyboardShortcuts.Name) {
    shortcutName = name
    super.init(frame: NSRect(x: 0, y: 0, width: 130, height: 24))
    bezelStyle = .rounded
    setButtonType(.momentaryPushIn)
    target = self
    action = #selector(beginRecording)
    toolTip = "Click, then press a shortcut. Press Delete to clear it."
    setAccessibilityLabel("Open dashboard shortcut")
    refreshTitle()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  isolated deinit {
    for observer in deactivationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
    if isRecording {
      KeyboardShortcuts.enable(shortcutName)
    }
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  func refreshTitle() {
    guard !isRecording else { return }
    if let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
      title = "\(shortcut)"
    } else {
      title = "Record Shortcut"
    }
  }

  @objc private func beginRecording() {
    guard !isRecording else { return }
    isRecording = true
    title = "Press Shortcut"
    guard window?.makeFirstResponder(self) == true else {
      isRecording = false
      refreshTitle()
      return
    }
    KeyboardShortcuts.disable(shortcutName)
    observeRecordingDeactivation()
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      self?.handle(event) ?? event
    }
  }

  override func resignFirstResponder() -> Bool {
    let didResign = super.resignFirstResponder()
    if didResign {
      finishRecording()
    }
    return didResign
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard event.type == .keyDown else {
      if event.window != window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
        window?.makeFirstResponder(nil)
      }
      return event
    }

    let modifiers = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)
    if Self.isFocusTraversalKey(event.keyCode, modifiers: modifiers) {
      window?.makeFirstResponder(nil)
      return event
    }
    if modifiers.isEmpty {
      switch event.keyCode {
      case 51, 117: // Delete / Forward Delete clears the shortcut.
        KeyboardShortcuts.setShortcut(nil, for: shortcutName)
        window?.makeFirstResponder(nil)
        return nil
      case 53: // Escape cancels recording.
        window?.makeFirstResponder(nil)
        return nil
      default:
        break
      }
    }

    guard let shortcut = KeyboardShortcuts.Shortcut(event: event),
          Self.hasAllowedModifiers(modifiers, key: shortcut.key),
          !shortcut.isTakenBySystem
    else {
      NSSound.beep()
      return nil
    }

    KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
    window?.makeFirstResponder(nil)
    return nil
  }

  private func finishRecording() {
    guard isRecording else { return }
    stopObservingRecordingDeactivation()
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    KeyboardShortcuts.enable(shortcutName)
    isRecording = false
    refreshTitle()
  }

  private func observeRecordingDeactivation() {
    let center = NotificationCenter.default
    deactivationObservers = [
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.finishRecording()
        }
      },
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: NSApplication.shared,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.finishRecording()
        }
      },
    ]
  }

  private func stopObservingRecordingDeactivation() {
    let center = NotificationCenter.default
    for observer in deactivationObservers {
      center.removeObserver(observer)
    }
    deactivationObservers.removeAll()
  }

  static func isFocusTraversalKey(
    _ keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> Bool {
    keyCode == 48 && modifiers.subtracting(.shift).isEmpty
  }

  static func hasAllowedModifiers(
    _ modifiers: NSEvent.ModifierFlags,
    key: KeyboardShortcuts.Key?
  ) -> Bool {
    let meaningfulModifiers = modifiers.intersection([.command, .control, .option])
    return !meaningfulModifiers.isEmpty || key.map(functionKeys.contains) == true
  }

  private static let functionKeys: Set<KeyboardShortcuts.Key> =
    [
      .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
      .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ]
}
