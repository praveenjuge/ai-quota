import AppKit

/// Native status-item menu (Battery-menu style): provider sections with
/// quota rows, then Refresh / Settings / Quit. All rows are stock menu
/// items: text rows plus draining-bar images on their own lines.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let store: UsageStore
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(store: UsageStore, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.store = store
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()
        menu.delegate = self
        // Explicit enabled states (auto-validation would re-enable
        // actionless rows, defeating the dimmed style).
        menu.autoenablesItems = false
        rebuild()
    }

    /// Rebuild items from the latest snapshots (cheap, synchronous).
    func rebuild() {
        menu.removeAllItems()
        let enabled = ProviderID.allCases.filter { SettingsStore.isEnabled($0) }
        // Pass 1: measure the widest text row so bars span exactly the
        // text width (plus the key-hint column), with no right gap.
        let barWidth = measureBarWidth(enabled: enabled)
        for (index, id) in enabled.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            addSection(for: id, barWidth: barWidth)
        }
        menu.addItem(.separator())
        if let last = store.lastRefresh {
            menu.addItem(info("Updated \(last.formatted(date: .omitted, time: .shortened))", dimmed: true))
        }
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AIQuota", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        Task {
            await store.refresh(userInitiated: true)
            self.rebuild()
        }
    }

    // MARK: - Sections

    private func addSection(for id: ProviderID, barWidth: CGFloat) {
        let snap = store.snapshot(for: id)
        menu.addItem(info(headerText(for: id, snap: snap), dimmed: true))
        if let message = snap?.state.message {
            menu.addItem(info(message, dimmed: true))
            return
        }
        var rows = 0
        rows += addRow(label: "Session", window: snap?.session, barWidth: barWidth)
        rows += addRow(label: "Weekly", window: snap?.weekly, barWidth: barWidth)
        for extra in snap?.extraRows ?? [] {
            rows += addRow(label: extra.label, window: extra.window, barWidth: barWidth)
        }
        if rows == 0 {
            menu.addItem(info("No usage reported yet", dimmed: true))
        }
    }

    /// One quota row: text line (reset countdown faded inline) plus a
    /// draining bar on its own line below. Returns 1 when rendered.
    @discardableResult
    private func addRow(label: String, window: UsageWindow?, barWidth: CGFloat) -> Int {
        guard let used = window?.usedPercent, let text = rowText(label: label, window: window) else { return 0 }
        let row = info("")
        row.attributedTitle = text
        menu.addItem(row)
        let barItem = NSMenuItem()
        let view = BarView(frame: NSRect(x: 0, y: 0, width: barWidth, height: 8))
        view.fraction = min(1, max(0, (100 - used) / 100))
        view.color = Self.barColor(forRemaining: 100 - used)
        barItem.view = view
        menu.addItem(barItem)
        return 1
    }

    private func headerText(for id: ProviderID, snap: ProviderSnapshot?) -> String {
        var header = id.displayName
        if let plan = snap?.plan { header += " · \(plan)" }
        return header
    }

    private func rowText(label: String, window: UsageWindow?) -> NSMutableAttributedString? {
        guard let used = window?.usedPercent else { return nil }
        let text = NSMutableAttributedString(
            string: "\(label) — \(Int((100 - used).rounded()))% left"
        )
        if let reset = resetText(window?.resetsAt) {
            text.append(NSAttributedString(
                string: " · \(reset)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return text
    }

    /// Widest text row in menu font, plus room for the key-hint column,
    /// so bar images span the full menu width with no right gap.
    private func measureBarWidth(enabled: [ProviderID]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        var widest: CGFloat = 0
        for id in enabled {
            let snap = store.snapshot(for: id)
            widest = max(widest, (headerText(for: id, snap: snap) as NSString)
                .size(withAttributes: [.font: font]).width)
            let windows: [(String, UsageWindow?)] = [("Session", snap?.session), ("Weekly", snap?.weekly)]
                + (snap?.extraRows.map { ($0.label, $0.window) } ?? [])
            for (label, window) in windows {
                if let text = rowText(label: label, window: window) {
                    let sized = NSMutableAttributedString(attributedString: text)
                    sized.addAttribute(.font, value: font, range: NSRange(location: 0, length: sized.length))
                    widest = max(widest, sized.size().width)
                }
            }
        }
        return min(460, max(220, widest + 84))
    }

    /// Non-functional row: full-contrast by default, gray when dimmed.
    private func info(_ text: String, dimmed: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: dimmed ? nil : #selector(noop), keyEquivalent: "")
        item.target = dimmed ? nil : self
        item.isEnabled = !dimmed
        return item
    }

    private func resetText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "resetting…" }
        if remaining < 3600 { return "resets in \(Int(remaining / 60))m" }
        if remaining < 86400 {
            let h = Int(remaining / 3600)
            let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            return m == 0 ? "resets in \(h)h" : "resets in \(h)h \(m)m"
        }
        return "resets in \(Int(remaining / 86400))d"
    }

    private static func barColor(forRemaining remaining: Double) -> NSColor {
        switch remaining {
        case 50...: .systemGreen
        case 25..<50: .systemYellow
        case 10..<25: .systemOrange
        default: .systemRed
        }
    }

    // MARK: - Actions

    @objc private func noop(_ sender: Any?) {}

    @objc private func refreshNow(_ sender: Any?) {
        Task { await store.refresh(userInitiated: true) }
    }

    @objc private func openSettings(_ sender: Any?) {
        onSettings()
    }

    @objc private func quitApp(_ sender: Any?) {
        onQuit()
    }
}

/// Bar-only menu item view. The menu stretches it to the full menu
/// width (including under the key-hint column), so the bar redraws
/// from its live bounds and always spans edge to edge.
final class BarView: NSView {
    var fraction: Double = 0
    var color: NSColor = .systemGreen

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let height: CGFloat = 6
        let y = (bounds.height - height) / 2
        let width = bounds.width
        NSColor.systemGray.withAlphaComponent(0.45).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: y, width: width, height: height),
            xRadius: height / 2,
            yRadius: height / 2
        ).fill()
        if fraction > 0 {
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: y, width: max(height, width * fraction), height: height),
                xRadius: height / 2,
                yRadius: height / 2
            ).fill()
        }
    }
}
