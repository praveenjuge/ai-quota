import AppKit

/// Plain AppKit entry point: the app is a status item plus one Settings
/// window, both AppKit-owned. SwiftUI's Settings scene only opens through
/// SettingsLink/openSettings, which a status-item NSMenu can't reach.
@main
enum DevbarApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: StatusMenu?
    private var store = UsageStore()
    private var refreshTimer: Timer?
    private let updater = UpdateController()
    private lazy var settingsWindow = SettingsWindow(updater: UpdateController.isAvailable ? updater : nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.mainMenu()

        if CommandLine.arguments.contains("--dump-usage") {
            Task {
                await store.refresh(userInitiated: true)
                print(Dump.json(store: store))
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--dump-ports") {
            Task {
                let ports = await PortScanner.scan(hidden: Set(SettingsStore.hiddenProcesses))
                print(Dump.json(ports: ports))
                NSApp.terminate(nil)
            }
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        statusItem = item
        updateIcon(caffeinated: false)

        let statusMenu = StatusMenu(
            store: store,
            updater: UpdateController.isAvailable ? updater : nil,
            onCaffeinateChange: { [weak self] in self?.updateIcon(caffeinated: $0) },
            onSettings: { [weak self] in self?.settingsWindow.show() },
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

    /// Accessory apps show no menu bar, but its key equivalents still work
    /// while the Settings window is key (⌘W closes it).
    private static func mainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Devbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        return main
    }

    /// A steaming cup replaces the pie chart while Caffeinate is on.
    private func updateIcon(caffeinated: Bool) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: caffeinated ? "cup.and.heat.waves.fill" : "chart.pie.fill",
            accessibilityDescription: caffeinated ? "Devbar, Caffeinate on" : "Devbar"
        )
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
                "account": snap.account.map(StatusMenu.masked) as Any,
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

    static func json(ports: [ListeningPort]) -> String {
        let rows: [[String: Any]] = ports.map {
            ["port": $0.port, "pid": $0.pid, "process": $0.process, "directory": $0.directory]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
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
