import AppKit
import SwiftUI

@main
struct AIQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: StatusMenu?
    private var store = UsageStore()
    private var refreshTimer: Timer?
    private let updater = UpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if CommandLine.arguments.contains("--dump-usage") {
            Task {
                await store.refresh(userInitiated: true)
                print(Dump.json(store: store))
                NSApp.terminate(nil)
            }
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "chart.pie.fill",
            accessibilityDescription: "AIQuota"
        )
        item.button?.imagePosition = .imageOnly
        statusItem = item

        let statusMenu = StatusMenu(
            store: store,
            updater: UpdateController.isAvailable ? updater : nil,
            onSettings: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            onQuit: { NSApp.terminate(nil) }
        )
        self.statusMenu = statusMenu
        item.menu = statusMenu.menu
        updater.onChange = { [weak statusMenu] in statusMenu?.updateUpdateItem() }
        updater.start()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: UsageStore.refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.store.refresh(userInitiated: false) }
        }
        Task { await store.refresh(userInitiated: false) }
    }
}

/// Headless JSON dump of the same pipeline the menu bar uses.
/// Used for testing; snapshots never contain tokens.
@MainActor
enum Dump {
    static func json(store: UsageStore) -> String {
        var root: [String: Any] = [:]
        for id in ProviderID.allCases {
            guard let snap = store.snapshot(for: id) else { continue }
            var entry: [String: Any] = [
                "plan": snap.plan as Any,
                "session": window(snap.session),
                "weekly": window(snap.weekly),
                "state": stateName(snap.state),
                "message": snap.state.message as Any,
            ]
            if snap.extraRows.isEmpty == false {
                entry["extra"] = snap.extraRows.map { [($0.label): window($0.window)] }
            }
            root[id.rawValue] = entry
        }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func window(_ w: UsageWindow) -> [String: Any] {
        var d: [String: Any] = [:]
        if let u = w.usedPercent { d["used_percent"] = u }
        if let r = w.remainingPercent { d["remaining_percent"] = r }
        if let t = w.resetsAt { d["resets_at"] = ISO8601DateFormatter().string(from: t) }
        return d
    }

    private static func stateName(_ s: ProviderState) -> String {
        switch s {
        case .ok: "ok"
        case .loggedOut: "logged_out"
        case .expired: "expired"
        case .keychainDenied: "keychain_denied"
        case .error: "error"
        case .transient: "transient"
        }
    }
}
