import Foundation
import Testing
@testable import QuotariCore

@Suite struct RegistryTests {
    @Test func everyProviderHasADescriptor() {
        #expect(ProviderRegistry.isComplete)
        for provider in UsageProvider.allCases {
            #expect(ProviderRegistry.descriptor(for: provider).id == provider)
        }
    }

    @Test func mockPipelineReturnsUsage() async throws {
        let descriptor = ProviderRegistry.descriptor(for: .cortex)
        let result = await descriptor.fetch(now: Date())
        let value = try result.get()
        #expect(value.usage.primary?.usedPercent == 82)
        #expect(value.sourceLabel == "Mock")
    }
}

@Suite struct FormatterTests {
    @Test func percentHandlesSubOnePercent() {
        #expect(UsageFormatter.percent(0.4) == "<1%")
        #expect(UsageFormatter.percent(82) == "82%")
        #expect(UsageFormatter.percent(0) == "0%")
    }

    @Test func resetCountdownFormats() {
        let now = Date()
        #expect(UsageFormatter.resetCountdown(to: nil, now: now) == nil)
        #expect(UsageFormatter.resetCountdown(to: now.addingTimeInterval(-10), now: now) == "now")
        let future = now.addingTimeInterval(3 * 3600 + 5 * 60)
        #expect(UsageFormatter.resetCountdown(to: future, now: now)?.hasPrefix("in 3h") == true)
    }
}
