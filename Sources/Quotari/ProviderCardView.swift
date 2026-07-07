import QuotariCore
import SwiftUI

struct ProviderCardView: View {
    let descriptor: ProviderDescriptor
    let snapshot: UsageSnapshot?
    let sourceLabel: String?
    let error: String?

    private var accent: Color {
        Color(
            red: descriptor.metadata.accent.r,
            green: descriptor.metadata.accent.g,
            blue: descriptor.metadata.accent.b
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snapshot {
                if let primary = snapshot.primary { windowRow("Session", primary) }
                if let secondary = snapshot.secondary { windowRow("Weekly", secondary) }
                ForEach(snapshot.extraWindows) { named in windowRow(named.title, named.window) }
            } else if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("Loading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var header: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(descriptor.metadata.displayName).font(.headline)
                Spacer()
                if let account = snapshot?.account {
                    Text(account).font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack {
                if let sourceLabel {
                    Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = snapshot?.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func windowRow(_ title: String, _ window: RateWindow) -> some View {
        let pace = UsagePace.compute(window: window, now: Date())
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline)
            bar(window.usedPercent)
            HStack(spacing: 6) {
                Text("\(UsageFormatter.percent(window.remainingPercent)) left")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
                    Text("Resets \(reset)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if window.usedPercent < 100, let pace,
               UsageFormatter.paceTrend(pace) != nil || pace.runsOutIn != nil {
                HStack(spacing: 6) {
                    if let trend = UsageFormatter.paceTrend(pace) {
                        Text(trend)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(UsageFormatter.paceProjection(pace))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(accessibilityValue(for: window))
    }

    private func accessibilityValue(for window: RateWindow) -> String {
        var value = "\(UsageFormatter.percent(window.remainingPercent)) left, \(Theme.statusWord(window.usedPercent))"
        if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
            value += ", resets \(reset)"
        }
        return value
    }

    private func bar(_ used: Double) -> some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, used / 100))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.usageTrack)
                Capsule()
                    .fill(accent)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 5)
    }
}
