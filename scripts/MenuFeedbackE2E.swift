import AppKit

/// Hosts the canonical menu in a signed test app and observes actual tracking.
@MainActor
final class FeedbackTest: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var status: StatusMenu!
    private let updater = UpdateController()
    private var isOpen = false
    private var didOpen = false
    private var stage = 0
    private var timer: Timer!
    private var ticks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for id in ProviderID.allCases {
            UserDefaults.standard.set(false, forKey: "provider.\(id.rawValue).enabled")
        }
        status = StatusMenu(store: UsageStore(), updater: updater, onCaffeinateChange: { _ in }, onSettings: {}, onQuit: {})
        status.menu.delegate = self
        updater.onChange = { [weak self] in self?.status.updateUpdateItem() }
        updater.start()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Update test"
        item.menu = status.menu
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        openMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        didOpen = true
        print("Menu opened")
        status.menuWillOpen(menu)
    }
    func menuDidClose(_ menu: NSMenu) { isOpen = false; print("Menu closed") }

    private func openMenu() {
        // A separate timer opens the blocking tracking loop; the feedback
        // timer must not be the callback that enters that loop.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.status.menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 600), in: nil)
            }
        }
    }

    private func tick() {
        ticks += 1
        guard ticks < 120 else { fail("feedback timeout") ; return }
        switch stage {
        case 0:
            // Opening the menu refreshes and rebuilds it while it tracks.
            guard isOpen else {
                if didOpen { fail("menu closed while refreshing") }
                return
            }
            guard status.menu.items.contains(where: { $0.title.hasPrefix("Refresh · Updated ") }) else { return }
            guard status.menu.items.allSatisfy({ $0.view == nil }) else {
                fail("action rows must be stock menu items")
                return
            }
            guard item("Check for updates…") == nil else {
                fail("checking for updates belongs in Settings")
                return
            }
            print("PASS: Menu stays open while the refresh rebuilds it")
            print("PASS: Refresh is one stock row with its update time in the title")
            stage = 1
            status.menu.cancelTracking()
        case 1:
            guard !isOpen, updater.enabled else { return }
            stage = 2
            // The Settings button calls this.
            updater.activate()
        case 2:
            guard updater.title == "You’re up to date" else { return }
            stage = 3
            openMenu()
        default:
            guard isOpen else { return }
            guard item(updater.title) == nil else {
                fail("the menu should only offer an update that is ready")
                return
            }
            print("PASS: An up-to-date check leaves the menu unchanged")
            timer.invalidate()
            status.menu.cancelTracking()
            NSApp.terminate(nil)
        }
    }

    private func item(_ title: String) -> NSMenuItem? {
        status.menu.items.first { $0.title == title }
    }
    private func fail(_ message: String) {
        print("FAIL: \(message)")
        exit(1)
    }
}

@main
struct MenuFeedbackE2E {
    static func main() {
        let app = NSApplication.shared
        let delegate = FeedbackTest()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
