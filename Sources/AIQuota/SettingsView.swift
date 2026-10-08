import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var launchAtLogin = SettingsStore.launchAtLogin
    @State private var needsApproval = SettingsStore.launchAtLoginNeedsApproval

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(ProviderID.allCases, id: \.self) { ProviderToggle(id: $0) }
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: {
                        SettingsStore.launchAtLogin = $0
                        syncLoginState()
                    }
                ))
                if needsApproval {
                    LabeledContent("Allow AIQuota in Login Items to finish.") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Refreshes every 10 minutes and when opened.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        // Approval happens in System Settings; pick it up on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLoginState()
        }
    }

    /// Re-reads the real login item state, which may differ from the request.
    private func syncLoginState() {
        launchAtLogin = SettingsStore.launchAtLogin
        needsApproval = SettingsStore.launchAtLoginNeedsApproval
    }
}

/// Stored under the same key the menu and refresh read.
private struct ProviderToggle: View {
    let id: ProviderID
    @AppStorage private var isOn: Bool

    init(id: ProviderID) {
        self.id = id
        _isOn = AppStorage(wrappedValue: true, SettingsStore.key(for: id))
    }

    var body: some View {
        Toggle(id.displayName, isOn: $isOn)
    }
}
