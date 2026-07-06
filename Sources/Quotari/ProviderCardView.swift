import QuotariCore
import SwiftUI

/// One provider's card: an accent chip with the initial, the name + source,
/// the headline usage %, and an animated gauge per window with reset time.
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
            headerRow
            content
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent.gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Text(String(descriptor.metadata.displayName.prefix(1)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.metadata.displayName).font(.subheadline.weight(.semibold))
                if let sourceLabel {
                    Text(sourceLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let used = snapshot?.highestUsedPercent {
                Text(UsageFormatter.percent(used))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.severity(used))
                    .contentTransition(.numericText())
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            VStack(spacing: 8) {
                if let primary = snapshot.primary { gaugeRow(title: "Session", window: primary) }
                if let secondary = snapshot.secondary { gaugeRow(title: "Weekly", window: secondary) }
            }
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func gaugeRow(title: String, window: RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let reset = UsageFormatter.resetCountdown(to: window.resetsAt) {
                    Label(reset, systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            gauge(window.usedPercent)
        }
    }

    private func gauge(_ used: Double) -> some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, used / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.severity(used).gradient)
                    .frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * fraction))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 7)
    }
}
