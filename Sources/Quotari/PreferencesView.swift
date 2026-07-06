import QuotariCore
import SwiftUI

struct PreferencesView: View {
    @Environment(UsageStore.self) private var store
    @State private var intervalMinutes: Double = 1

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Icon", selection: Binding(
                    get: { store.iconStyle },
                    set: { store.iconStyle = $0 }))
                {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Text(style.label)
                            .tag(style)
                    }
                }
            }
            Section("Refresh") {
                Slider(value: $intervalMinutes, in: 1...30, step: 1) {
                    Text("Interval")
                } minimumValueLabel: {
                    Text("1m")
                } maximumValueLabel: {
                    Text("30m")
                }
                Text("Every \(Int(intervalMinutes)) minute(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "Quotari")
                LabeledContent("Providers", value: "\(store.providers.count) (mock)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 300)
        .onAppear { intervalMinutes = store.refreshInterval / 60 }
        .onChange(of: intervalMinutes) { _, newValue in
            store.refreshInterval = newValue * 60
        }
    }
}
