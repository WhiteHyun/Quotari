import QuotariCore
import SwiftUI

struct ProviderCardView: View {
    let descriptor: ProviderDescriptor
    let snapshot: UsageSnapshot?
    let sourceLabel: String?
    let error: String?

    private var accent: Color {
        Color(red: descriptor.metadata.accent.r,
              green: descriptor.metadata.accent.g,
              blue: descriptor.metadata.accent.b)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(descriptor.metadata.displayName).font(.headline)
                Spacer()
                if let sourceLabel {
                    Text(sourceLabel).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let snapshot {
                if let primary = snapshot.primary { windowRow("Session", primary) }
                if let secondary = snapshot.secondary { windowRow("Weekly", secondary) }
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2)
            } else {
                Text("Loading…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func windowRow(_ title: String, _ window: RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline)
            bar(window.usedPercent)
            HStack(spacing: 6) {
                Text("\(UsageFormatter.percent(window.usedPercent)) used")
                    .font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
                    Text("resets \(reset)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .animation(.default, value: window.usedPercent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(accessibilityValue(for: window))
    }

    private func accessibilityValue(for window: RateWindow) -> String {
        var value = "\(UsageFormatter.percent(window.usedPercent)) used, \(Theme.statusWord(window.usedPercent))"
        if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
            value += ", resets \(reset)"
        }
        return value
    }

    private func bar(_ used: Double) -> some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, used / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.usageTrack)
                Capsule()
                    .fill(accent)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 5)
    }
}
