import Foundation

public extension AccountCaptureService {
  func registeredAccounts(for provider: UsageProvider) throws -> [CapturedAccount] {
    try capturedAccounts.registeredAccounts(for: provider)
  }
}
