import AppKit
import CustomDump
@testable import Quotari
@testable import QuotariCore
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct ProviderAccountPopoverPresentationTests {
  @Test func longProcessListKeepsTheConfirmationHeightBounded() {
    _ = NSApplication.shared
    let state = ConfirmationState()
    state.confirmation = .switchBlocked(
      popoverAccount(source: .quotariRegistry(id: "claude:saved")),
      CLIActivitySnapshot(
        provider: .claude,
        processes: (1 ... 100).map { "claude (PID \($0))" }
      )
    )
    let binding = Binding(
      get: { state.confirmation },
      set: { state.confirmation = $0 }
    )
    let hostingView = NSHostingView(
      rootView: ProviderAccountPopoverConfirmationView(confirmation: binding) { _ in }
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 330, height: 500)
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.height < 440)
  }

  @Test func providerPopoverOwnsTheConfirmationInsideItsTransientWindow() throws {
    _ = NSApplication.shared
    let descriptor = ProviderFixtures.descriptor(for: .claude)
    let confirmation = ProviderAccountPopoverConfirmation.addClaudeAccount(
      CLIActivitySnapshot(provider: .claude, processes: ["claude (PID 42)"])
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      startsAutomatically: false
    )
    let fixture = TransientPopoverFixture(
      rootView: ProviderAccountPopover(
        descriptor: descriptor,
        initialConfirmation: confirmation
      )
      .environment(store)
    )
    defer { fixture.close() }

    fixture.show()
    let originalWindow = try #require(fixture.contentWindow)

    #expect(fixture.popover.isShown)
    #expect(fixture.contentWindow === originalWindow)
    fixture.sendKey(keyCode: 53, characters: "\u{1B}")
    fixture.pumpRunLoop()

    #expect(fixture.popover.isShown)
    #expect(fixture.contentWindow === originalWindow)
  }

  @Test func retryButtonRemainsInsideTheTransientPopoverWithoutDismissingTheBlocker() throws {
    _ = NSApplication.shared
    let state = ConfirmationState()
    let confirmation = ProviderAccountPopoverConfirmation.switchBlocked(
      popoverAccount(source: .quotariRegistry(id: "claude:saved")),
      CLIActivitySnapshot(provider: .claude, processes: ["claude (PID 42)"])
    )
    state.confirmation = confirmation
    let binding = Binding(
      get: { state.confirmation },
      set: { state.confirmation = $0 }
    )
    let fixture = TransientPopoverFixture(
      rootView: ProviderAccountPopoverConfirmationView(confirmation: binding) { received in
        state.confirmedID = received.id
        state.confirmCount += 1
      }
    )
    defer { fixture.close() }

    fixture.show()
    let originalWindow = try #require(fixture.contentWindow)

    #expect(fixture.popover.isShown)
    fixture.sendKey(keyCode: 36, characters: "\r")
    fixture.pumpRunLoop()

    #expect(fixture.popover.isShown)
    #expect(fixture.contentWindow === originalWindow)
    expectNoDifference(state.confirmCount, 1)
    expectNoDifference(state.confirmedID, confirmation.id)
    expectNoDifference(state.confirmation?.id, confirmation.id)
  }

  @Test func cancellingClearsTheConfirmationWithoutRunningTheOperation() throws {
    _ = NSApplication.shared
    let state = ConfirmationState()
    state.confirmation = .addClaudeAccount(
      CLIActivitySnapshot(provider: .claude, processes: ["claude (PID 42)"])
    )
    let binding = Binding(
      get: { state.confirmation },
      set: { state.confirmation = $0 }
    )
    let fixture = TransientPopoverFixture(
      rootView: ProviderAccountPopoverConfirmationView(confirmation: binding) { _ in
        state.confirmCount += 1
      }
    )
    defer { fixture.close() }

    fixture.show()
    let originalWindow = try #require(fixture.contentWindow)

    fixture.sendKey(keyCode: 53, characters: "\u{1B}")
    fixture.pumpRunLoop()

    #expect(fixture.popover.isShown)
    #expect(fixture.contentWindow === originalWindow)
    expectNoDifference(state.confirmCount, 0)
    #expect(state.confirmation == nil)
  }
}

@MainActor
private final class ConfirmationState {
  var confirmation: ProviderAccountPopoverConfirmation?
  var confirmCount = 0
  var confirmedID: String?
}

@MainActor
private final class TransientPopoverFixture<Content: View> {
  let popover = NSPopover()
  let hostingView: NSView

  private let anchor = NSButton(frame: NSRect(x: 20, y: 20, width: 80, height: 28))
  private let window: NSWindow

  init(rootView: Content) {
    let controller = NSHostingController(rootView: rootView)
    hostingView = controller.view
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 330, height: 420)
    popover.contentViewController = controller

    window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 140, height: 80),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = anchor
  }

  var contentWindow: NSWindow? {
    hostingView.window
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    pumpRunLoop()
  }

  func close() {
    popover.performClose(nil)
    window.orderOut(nil)
  }

  func pumpRunLoop() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }

  func sendKey(keyCode: UInt16, characters: String) {
    guard let window = contentWindow else { return }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard let event = NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      ) else { continue }
      window.sendEvent(event)
    }
  }
}

private func popoverAccount(source: ProviderCredentialSource) -> ProviderAccount {
  ProviderAccount(
    provider: .claude,
    displayName: "Claude",
    detail: nil,
    credentialSource: source
  )
}
