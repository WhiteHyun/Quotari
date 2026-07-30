struct CLIActivityInspectionState {
  private(set) var isRunning = false

  mutating func begin() -> Bool {
    guard !isRunning else { return false }
    isRunning = true
    return true
  }

  mutating func finish() {
    isRunning = false
  }
}
