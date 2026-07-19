import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct SettingsWindowControllerTests {
  @Test func showsSettingsWindowWithoutAnAppBundle() {
    let store = UsageStore.isolatedForTesting(
      providers: ProviderRegistry.all,
      startsAutomatically: false
    )
    let controller = SettingsWindowController()
    defer { controller.close() }

    controller.show(store: store)

    #expect(controller.isVisible)
    #expect(controller.windowTitle == "Settings")
    #expect(controller.isResizable)
    #expect(controller.minimumContentSize == NSSize(width: 840, height: 560))
    #expect(controller.isMovableByWindowBackground == false)
  }

  @Test func showingSettingsBeginsFreshAccountDiscovery() async {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Codex CLI",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    let discovery = GatedAccountRediscovery(account: account)
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      startsAutomatically: false
    )
    let controller = SettingsWindowController()
    defer { controller.close() }

    controller.show(store: store)
    let reload = store.inFlightAccountReload
    await discovery.waitUntilRequestStarts()

    #expect(reload != nil)
    #expect(await discovery.requestCount == 1)

    await discovery.resume()
    await reload?.value

    #expect(store.accounts[.codex] == [account])
  }
}
