import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let updater: UpdateController?
    @State private var launchAtLogin = SettingsStore.launchAtLogin
    @State private var needsApproval = SettingsStore.launchAtLoginNeedsApproval
    @State private var hiddenProcesses = SettingsStore.hiddenProcesses
    @AppStorage(SettingsStore.showDevServersKey) private var showDevServers = true

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(ProviderID.allCases, id: \.self) { ProviderToggle(id: $0) }
            }
            Section {
                Toggle("Show dev servers", isOn: $showDevServers)
                if !hiddenProcesses.isEmpty {
                    LabeledContent("Hidden: \(hiddenProcesses.formatted(.list(type: .and)))") {
                        Button("Show All") {
                            SettingsStore.hiddenProcesses = []
                            hiddenProcesses = []
                        }
                    }
                }
            } header: {
                Text("Dev Servers")
            } footer: {
                Text("Ports opened by processes started from a project folder.")
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
                    LabeledContent("Allow Devbar in Login Items to finish.") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Refreshes every 10 minutes and when opened.")
            }
            if let updater {
                Section {
                    LabeledContent("Version \(Self.version)") {
                        Button(updater.title) { updater.activate() }
                            .disabled(!updater.enabled)
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Updates download on their own. Restart from the menu when one is ready.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        // Approval happens in System Settings; pick it up on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLoginState()
        }
        // Processes are hidden from the menu, possibly while this window is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            hiddenProcesses = SettingsStore.hiddenProcesses
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
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

/// The one Settings window, created on first use and reused after.
@MainActor
final class SettingsWindow {
    private let updater: UpdateController?
    private var window: NSWindow?

    init(updater: UpdateController?) {
        self.updater = updater
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(updater: updater)))
        window.title = "Devbar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Open on the Space the menu was used from, even over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        return window
    }
}
