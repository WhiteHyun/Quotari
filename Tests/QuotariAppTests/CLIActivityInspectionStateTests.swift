@testable import Quotari
import Testing

struct CLIActivityInspectionStateTests {
  @Test func serializesActivityInspectionsUntilTheCurrentRequestFinishes() {
    var state = CLIActivityInspectionState()

    let firstRequest = state.begin()
    #expect(firstRequest)
    #expect(state.isRunning)
    let overlappingRequest = state.begin()
    #expect(!overlappingRequest)

    state.finish()

    #expect(!state.isRunning)
    let nextRequest = state.begin()
    #expect(nextRequest)
  }
}
