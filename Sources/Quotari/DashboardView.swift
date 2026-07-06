import AppKit
import QuotariCore
import SwiftUI

/// The popover shown from the menu bar: a titled header with a live usage
/// summary, a scrollable list of provider cards, and a compact icon footer.
struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.providers, id: \.id) { descriptor in
                        ProviderCardView(
                            descriptor: descriptor,
                            snapshot: store.snapshots[descriptor.id],
                            sourceLabel: store.sourceLabels[descriptor.id],
                            error: store.errors[descriptor.id])
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quotari").font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small).frame(width: 22, height: 22)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaryText: String {
        let count = store.providers.count
        guard !store.snapshots.isEmpty else { return "\(count) providers · loading…" }
        return "\(count) providers · peak \(UsageFormatter.percent(store.highestUsedPercent))"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let last = store.lastRefresh {
                Label(last.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Quotari")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
