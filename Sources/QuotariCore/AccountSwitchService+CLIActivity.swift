import Foundation

extension AccountSwitchService {
  public func cliActivitySnapshot(for provider: UsageProvider) throws -> CLIActivitySnapshot {
    try CLIActivitySnapshot(provider: provider, processes: activeCLIProcessRecords(provider))
  }

  func requireCLIInactive(_ provider: UsageProvider) throws {
    let active = try checkedActiveCLIProcesses(provider)
    let blocked = CLIActivityApprovalContext.snapshot?.unapprovedProcesses(
      for: provider,
      activeProcesses: active
    ) ?? active.map(\.displayName)
    guard blocked.isEmpty else {
      throw AccountSwitchError.cliStillRunning(processes: blocked)
    }
  }

  func checkedActiveCLIProcesses(_ provider: UsageProvider) throws -> [CLIActivityProcess] {
    let active: [CLIActivityProcess]
    do {
      active = try activeCLIProcessRecords(provider)
    } catch {
      throw AccountSwitchError.cliActivityCheckFailed(underlying: error.localizedDescription)
    }
    return active
  }
}
