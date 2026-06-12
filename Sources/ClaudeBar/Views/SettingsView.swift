import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled

    // Edit budget in millions for a friendlier control.
    private var budgetMillions: Binding<Double> {
        Binding(get: { Double(store.fiveHourTokenBudget) / 1_000_000 },
                set: { store.fiveHourTokenBudget = Int($0 * 1_000_000) })
    }

    var body: some View {
        Form {
            Section("Plan limits (live)") {
                Toggle("Show real session & weekly limits", isOn: $store.enableLiveLimits)
                Text("Fetches your real Session (5h) and Weekly (7d) usage from Claude's usage endpoint using your Claude Code login. Requires network; the first fetch may ask permission to read your credentials from the Keychain. Cached for 3 min to avoid rate limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        // If registration fails (e.g. running un-bundled), revert the toggle.
                        if !LoginItem.setEnabled(on) { launchAtLogin = LoginItem.isEnabled }
                    }
            }

            Section("Menu bar") {
                Picker("Show", selection: Binding(
                    get: { store.barMetric },
                    set: { store.barMetric = $0 })) {
                    ForEach(BarMetric.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Alerts") {
                HStack {
                    Text("Warn at")
                    Slider(value: Binding(
                        get: { Double(store.warnThreshold) },
                        set: { store.warnThreshold = Int($0) }), in: 50...100, step: 5)
                    Text("\(store.warnThreshold)%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Toggle("Notify when a limit crosses the threshold", isOn: $store.notifyOnWarning)
                    .disabled(!store.enableLiveLimits)
                Text("The menu-bar icon turns into an orange ⚠︎ when your session or weekly limit passes this threshold.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Picker("Interval", selection: $store.refreshInterval) {
                    Text("30 sec").tag(30.0)
                    Text("1 min").tag(60.0)
                    Text("5 min").tag(300.0)
                    Text("15 min").tag(900.0)
                }
            }

            Section("5-hour window meter") {
                HStack {
                    Slider(value: budgetMillions, in: 10...500, step: 10)
                    Text("\(Int(budgetMillions.wrappedValue))M")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("Soft budget the meter fills against. Claude doesn't publish an exact 5-hour token cap, so set this to match your plan's feel.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Costs are estimates from public list prices. Override per-model rates in ~/.claudebar/pricing.json")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 380)
    }
}
