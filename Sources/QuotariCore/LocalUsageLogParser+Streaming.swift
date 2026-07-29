import Foundation

extension LocalUsageCostScanner {
  func consumeCompleteLines(
    from pending: inout Data,
    newlineSearchOffset: inout Int,
    body: (Data) -> Bool
  ) -> LocalUsageLineReadOutcome? {
    var lineStart = pending.startIndex
    let boundedSearchOffset = min(newlineSearchOffset, pending.count)
    var searchStart = pending.index(pending.startIndex, offsetBy: boundedSearchOffset)
    while let newline = pending[searchStart...].firstIndex(of: 0x0A) {
      guard !Task.isCancelled else { return .cancelled }
      let line = normalizedLine(pending.subdata(in: lineStart ..< newline))
      guard line.isEmpty || autoreleasepool(invoking: { body(line) }) else {
        return .failure
      }
      lineStart = pending.index(after: newline)
      searchStart = lineStart
    }
    if lineStart > pending.startIndex {
      pending.removeSubrange(pending.startIndex ..< lineStart)
    }
    newlineSearchOffset = pending.count
    return nil
  }
}
