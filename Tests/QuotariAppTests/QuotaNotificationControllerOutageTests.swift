import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension QuotaNotificationControllerTests {
  @Test func outageAlertsAreDeliveredOnlyWhenTurnedOn() async throws {
    let defaults = try makeDefaults("outage-alerts")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let event = ProviderOutageEvent.started(provider: .codex, title: "Elevated errors")

    await controller.deliverOutageAlert(event)
    #expect(center.attemptedStatusAlerts.isEmpty)

    controller.alertsOnProviderOutages = true
    await controller.deliverOutageAlert(event)
    #expect(center.attemptedStatusAlerts.map(\.event) == [event])
  }

  @Test func outageAlertsRespectTheProviderToggle() async throws {
    let defaults = try makeDefaults("outage-alerts-provider")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    controller.alertsOnProviderOutages = true
    controller[providerEnabled: .codex] = false

    await controller.deliverOutageAlert(.resolved(provider: .codex, title: "Elevated errors"))

    #expect(center.attemptedStatusAlerts.isEmpty)
  }
}
