import Foundation
@testable import Quotari
import ServiceManagement
import Testing

@MainActor
struct LoginItemControllerTests {
  final class ServiceStub: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var error: Error?
    var openedSystemSettings = false

    func register() throws {
      if let error {
        throw error
      }
      status = .enabled
    }

    func unregister() throws {
      if let error {
        throw error
      }
      status = .notRegistered
    }

    func openSystemSettings() {
      openedSystemSettings = true
    }
  }

  private static func denied(_ message: String = "denied") -> NSError {
    NSError(domain: "quotari.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  @Test func togglingRegistersAndUnregistersTheLoginItem() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)

    controller.setEnabled(true)
    #expect(service.status == .enabled)
    #expect(controller.isEnabled)

    controller.setEnabled(false)
    #expect(service.status == .notRegistered)
    #expect(!controller.isEnabled)
  }

  @Test func registrationFailureStaysDisabledAndRecordsTheError() {
    let service = ServiceStub()
    service.error = Self.denied()
    let controller = LoginItemController(service: service)

    controller.setEnabled(true)

    #expect(!controller.isEnabled)
    #expect(controller.lastError == "denied")
  }

  @Test func unregistrationFailureStaysEnabledAndRecordsTheError() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)

    service.error = Self.denied()
    controller.setEnabled(false)

    #expect(controller.isEnabled)
    #expect(controller.lastError == "denied")
  }

  @Test func successAfterFailureClearsTheRecordedError() {
    let service = ServiceStub()
    service.error = Self.denied()
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)

    service.error = nil
    controller.setEnabled(true)

    #expect(controller.isEnabled)
    #expect(controller.lastError == nil)
  }

  @Test func launchesAtLoginRoutesWritesThroughSetEnabled() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)

    controller.launchesAtLogin = true

    #expect(service.status == .enabled)
    #expect(controller.launchesAtLogin)
  }

  @Test func withoutABundledServiceTheControlIsUnavailable() {
    let controller = LoginItemController(service: nil)

    #expect(!controller.isAvailable)
    controller.setEnabled(true)
    #expect(!controller.isEnabled)
  }

  @Test func refreshStatusPicksUpChangesMadeInSystemSettings() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)

    service.status = .enabled
    #expect(!controller.isEnabled)

    controller.refreshStatus()
    #expect(controller.isEnabled)
  }

  @Test func refreshStatusClearsAStaleErrorOnceExternallyApproved() {
    let service = ServiceStub()
    service.error = Self.denied()
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)
    #expect(controller.lastError != nil)

    service.status = .enabled
    controller.refreshStatus()

    #expect(controller.isEnabled)
    #expect(controller.lastError == nil)
  }

  @Test func noOpToggleStillResyncsAStaleCachedStatus() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)
    #expect(controller.isEnabled)

    // Disabled externally: toggling off matches the service's real state, so
    // no unregister call happens, but the cached status must still resync.
    service.status = .notRegistered
    controller.setEnabled(false)

    #expect(!controller.isEnabled)
  }

  @Test func staleToggleClickAfterExternalApprovalClearsTheOldError() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)
    service.status = .requiresApproval
    service.error = Self.denied()
    controller.setEnabled(true)
    #expect(controller.lastError != nil)

    // Approved in System Settings; the toggle still shows off, so the user
    // clicks it on — a no-op against the real state, but it must resync.
    service.status = .enabled
    controller.setEnabled(true)

    #expect(controller.isEnabled)
    #expect(controller.lastError == nil)
  }

  @Test func notFoundStatusIsSurfacedDistinctly() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)

    service.status = .notFound
    controller.refreshStatus()

    #expect(controller.serviceNotFound)
    #expect(!controller.isEnabled)
    #expect(!controller.requiresApproval)
  }

  @Test func revokedConsentSurfacesApprovalPathInsteadOfSilentFailure() {
    let service = ServiceStub()
    let controller = LoginItemController(service: service)
    service.status = .requiresApproval
    controller.refreshStatus()

    #expect(controller.requiresApproval)
    #expect(!controller.isEnabled)

    // Retrying register while approval is pending keeps failing…
    service.error = Self.denied("Operation not permitted")
    controller.setEnabled(true)
    #expect(controller.requiresApproval)
    #expect(controller.lastError == "Operation not permitted")

    // …the recovery path is System Settings.
    controller.openSystemSettings()
    #expect(service.openedSystemSettings)
  }
}
