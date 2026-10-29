import Foundation
@testable import QuotariCore
import Testing

struct QuotaHistoryTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private let key = QuotaSeriesKey(provider: .codex, accountID: "work", window: .weekly)
  private let minute: TimeInterval = 60

  @Test func observationsOlderThanTheRetentionAreDropped() {
    var history = QuotaHistory()
    history.record(observation(10, at: start), for: key)

    history.record(observation(20, at: start.addingTimeInterval(QuotaHistory.retention + minute)), for: key)

    #expect(history.observations(for: key).map(\.usedPercent) == [20])
  }

  @Test func unchangedReadingsAreSpacedButChangesAreKept() {
    var history = QuotaHistory()
    history.record(observation(10, at: start), for: key)
    history.record(observation(10, at: start.addingTimeInterval(1 * minute)), for: key)
    history.record(observation(11, at: start.addingTimeInterval(2 * minute)), for: key)
    history.record(observation(11, at: start.addingTimeInterval(8 * minute)), for: key)

    #expect(history.observations(for: key).map(\.usedPercent) == [10, 11, 11])
  }

  @Test func theCurrentCycleStartsAfterTheLastReset() {
    var history = QuotaHistory()
    let firstReset = start.addingTimeInterval(60 * minute)
    let secondReset = firstReset.addingTimeInterval(5 * 3600)
    history.record(QuotaObservation(usedPercent: 80, resetsAt: firstReset, observedAt: start), for: key)
    history.record(
      QuotaObservation(usedPercent: 5, resetsAt: secondReset, observedAt: firstReset.addingTimeInterval(minute)),
      for: key
    )
    // Reset times wobble by seconds between readings of the same cycle.
    history.record(
      QuotaObservation(
        usedPercent: 9,
        resetsAt: secondReset.addingTimeInterval(2),
        observedAt: firstReset.addingTimeInterval(20 * minute)
      ),
      for: key
    )

    #expect(history.currentCycle(for: key, resetsAt: secondReset).map(\.usedPercent) == [5, 9])
  }

  private func observation(_ used: Double, at date: Date) -> QuotaObservation {
    QuotaObservation(usedPercent: used, resetsAt: start.addingTimeInterval(7 * 86400), observedAt: date)
  }
}

struct QuotaBurndownTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private let minute: TimeInterval = 60

  @Test func gapsSplitTheBurndownInsteadOfBeingBridged() {
    let readings = [0, 5, 10, 40, 45].map { offset in reading(Double(offset), atMinute: offset) }

    // 10 → 40 is a 30-minute gap: the Mac slept or fetches failed.
    #expect(QuotaBurndown.segments(readings).map { $0.map(\.usedPercent) } == [[0, 5, 10], [40, 45]])
  }

  @Test func theRecentBurnRateUsesTheLatestSegmentWithinTheLookback() throws {
    // 1% per 5 minutes in the last hour; older readings rose faster.
    let readings = [reading(0, atMinute: 0), reading(30, atMinute: 10)]
      + (0 ... 12).map { reading(40 + Double($0), atMinute: 60 + $0 * 5) }
    let now = start.addingTimeInterval(120 * minute)

    let rate = try #require(QuotaBurndown.recentBurnRate(readings, now: now, lookback: 3600, minimumSpan: 15 * minute))

    #expect(abs(rate - 1.0 / 300) < 1e-9)
  }

  @Test func tooLittleDataOrAResetGivesNoRecentRate() {
    let now = start.addingTimeInterval(30 * minute)
    let short = [reading(10, atMinute: 20), reading(12, atMinute: 25)]
    let dropped = [reading(40, atMinute: 0), reading(5, atMinute: 25)]

    #expect(QuotaBurndown.recentBurnRate(short, now: now, lookback: 3600, minimumSpan: 15 * minute) == nil)
    #expect(QuotaBurndown.recentBurnRate(dropped, now: now, lookback: 3600, minimumSpan: 15 * minute) == nil)
  }

  private func reading(_ used: Double, atMinute offset: Int) -> QuotaObservation {
    QuotaObservation(
      usedPercent: used,
      resetsAt: start.addingTimeInterval(7 * 86400),
      observedAt: start.addingTimeInterval(TimeInterval(offset) * minute)
    )
  }
}

struct QuotaHistoryStoreTests {
  @Test func historySurvivesAReloadAndAMissingFileStartsEmpty() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quota-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = QuotaHistoryStore(url: url)
    let key = QuotaSeriesKey(provider: .claude, accountID: "personal", window: .session)
    var history = QuotaHistory()
    history.record(
      QuotaObservation(usedPercent: 12, resetsAt: nil, observedAt: Date(timeIntervalSince1970: 1_800_000_000)),
      for: key
    )

    #expect(store.load() == QuotaHistory())
    try store.save(history)
    #expect(store.load() == history)
  }
}
