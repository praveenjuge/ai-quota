import SwiftUI

struct SettingsView: View {
    @State private var codexEnabled = SettingsStore.isEnabled(.codex)
    @State private var claudeEnabled = SettingsStore.isEnabled(.claude)
    @State private var museEnabled = SettingsStore.isEnabled(.muse)
    @State private var launchAtLogin = SettingsStore.launchAtLogin

    var body: some View {
        Form {
            Section("Providers") {
                Toggle("Codex", isOn: $codexEnabled)
                    .onChange(of: codexEnabled) { _, v in SettingsStore.setEnabled(.codex, v) }
                Toggle("Claude", isOn: $claudeEnabled)
                    .onChange(of: claudeEnabled) { _, v in SettingsStore.setEnabled(.claude, v) }
                Toggle("Muse", isOn: $museEnabled)
                    .onChange(of: museEnabled) { _, v in SettingsStore.setEnabled(.muse, v) }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        SettingsStore.launchAtLogin = v
                        launchAtLogin = SettingsStore.launchAtLogin
                    }
                Text("Refreshes every 10 minutes and when opened.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
