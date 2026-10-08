import AppKit

/// Hosts the canonical menu in a signed test app and observes actual tracking.
@MainActor
final class FeedbackTest: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var status: StatusMenu!
    private let updater = UpdateController()
    private var isOpen = false
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
        guard isOpen else {
            if stage == 0 {
                openMenu()
            } else {
                fail("menu closed during feedback")
            }
            return
        }
        switch stage {
        case 0:
            stage = 1
            click("Refresh")
        case 1:
            guard status.menu.items.contains(where: { $0.title == "Refresh" }) else { return }
            guard let row = status.menu.items.first(where: { $0.title == "Refresh" }),
                  let label = row.view?.subviews.compactMap({ $0 as? NSTextField }).first,
                  label.stringValue.hasPrefix("Updated "),
                  let button = row.view?.subviews.first as? NSButton,
                  button.frame.maxX + 8 <= label.frame.minX,
                  !status.menu.items.contains(where: { $0.title.hasPrefix("Updated ") }) else {
                fail("refresh and timestamp must share one row without overlap")
                return
            }
            guard updater.enabled else { return }
            print("PASS: Refresh and timestamp share one row without overlap")
            print("PASS: Refresh keeps menu tracking")
            stage = 2
            click("Check for updates…")
        default:
            guard updater.title == "You’re up to date" else { return }
            print("PASS: Check for updates keeps menu tracking and shows result")
            if CommandLine.arguments.count > 1,
               let content = status.menu.items.compactMap({ $0.view?.window?.contentView }).first,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("menu-feedback.png"))
                }
            }
            timer.invalidate()
            status.menu.cancelTracking()
            NSApp.terminate(nil)
        }
    }

    private func click(_ title: String) {
        guard let row = status.menu.items.first(where: { $0.title == title }),
              let button = row.view?.subviews.first as? NSButton else {
            fail("missing button: \(title)")
            return
        }
        button.performClick(nil)
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
