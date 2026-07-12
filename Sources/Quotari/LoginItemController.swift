import Foundation
import Observation
import ServiceManagement

/// Seam over `SMAppService` so tests can drive login-item state without
/// touching the real service registry.
@MainActor
protocol LoginItemService {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
  func openSystemSettings()
}

extension SMAppService: LoginItemService {
  func openSystemSettings() {
    Self.openSystemSettingsLoginItems()
  }
}

/// Wraps `SMAppService.mainApp`. Registration needs a packaged `.app` bundle;
/// `swift run` and test builds get the disabled state so development never
/// installs a login item.
@MainActor
@Observable
final class LoginItemController {
  static let shared = LoginItemController()

  private let service: (any LoginItemService)?
  private(set) var status: SMAppService.Status
  private(set) var lastError: String?

  var isAvailable: Bool {
    service != nil
  }

  var isEnabled: Bool {
    status == .enabled
  }

  /// Consent was revoked in System Settings; `register()` alone can't recover
  /// from this state, the user has to re-approve the item there.
  var requiresApproval: Bool {
    status == .requiresApproval
  }

  /// The system can't locate the login item (e.g. a broken install); the
  /// toggle still works but the state deserves an explanation.
  var serviceNotFound: Bool {
    status == .notFound
  }

  /// Settable surface for the Settings toggle: writing routes through
  /// `setEnabled`, so a failed registration snaps the toggle back.
  var launchesAtLogin: Bool {
    get { isEnabled }
    set { setEnabled(newValue) }
  }

  init(service: (any LoginItemService)? = LoginItemController.bundledAppService()) {
    self.service = service
    status = service?.status ?? .notRegistered
  }

  static func bundledAppService() -> (any LoginItemService)? {
    Bundle.main.bundleURL.pathExtension == "app" ? SMAppService.mainApp : nil
  }

  func setEnabled(_ enabled: Bool) {
    guard let service else { return }
    guard enabled != (service.status == .enabled) else {
      // System Settings can change the real state behind our back: treat the
      // no-op toggle like any other resync so stale status and errors clear.
      refreshStatus()
      return
    }
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    status = service.status
  }

  func openSystemSettings() {
    service?.openSystemSettings()
  }

  /// The user can flip the login item in System Settings behind our back;
  /// re-read the real status on demand (e.g. whenever Settings opens).
  func refreshStatus() {
    guard let service else { return }
    status = service.status
    if status == .enabled {
      lastError = nil
    }
  }
}
