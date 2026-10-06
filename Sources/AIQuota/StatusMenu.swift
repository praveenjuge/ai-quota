import AppKit

/// Native status-item menu (Battery-menu style): provider sections with
/// quota rows, then Refresh / Settings / Quit. All rows are stock menu
/// items: text rows plus native capacity indicators on their own lines.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private var renderedMenu = NSMenu()
    private let store: UsageStore
    private let updater: UpdateController?
    private var updateItem: NSMenuItem?
    private var refreshItem: NSMenuItem?
    private var refreshView: MenuActionView?
    private var updateView: MenuActionView?
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(store: UsageStore, updater: UpdateController?, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.store = store
        self.updater = updater
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
        let previousItems = menu.items
        renderedMenu = NSMenu()
        let enabled = ProviderID.allCases.filter { SettingsStore.isEnabled($0) }
        // Match the menu width while keeping capacity indicators inset
        // from the edges of their full-width menu-item views.
        let refreshDetail = store.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
        let refreshWidth = (("Refreshing…" + (refreshDetail ?? "")) as NSString)
            .size(withAttributes: [.font: NSFont.menuFont(ofSize: NSFont.systemFontSize)]).width + 40
        let barWidth = max(measureBarWidth(enabled: enabled), refreshWidth)
        for (index, id) in enabled.enumerated() {
            if index > 0 { renderedMenu.addItem(.separator()) }
            addSection(for: id, barWidth: barWidth)
        }
        renderedMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        let refreshView = MenuActionView(title: store.isRefreshing ? "Refreshing…" : "Refresh", width: barWidth, detail: refreshDetail) { [weak self] in
            self?.refreshNow(nil)
        }
        refreshView.update(title: store.isRefreshing ? "Refreshing…" : "Refresh", enabled: !store.isRefreshing)
        refresh.view = refreshView
        self.refreshView = refreshView
        refreshItem = refresh
        renderedMenu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        renderedMenu.addItem(settings)
        if let updater {
            let item = NSMenuItem(title: updater.title, action: #selector(updateApp), keyEquivalent: "")
            item.target = self
            item.isEnabled = updater.enabled
            updateItem = item
            let view = MenuActionView(title: updater.title, width: barWidth) { [weak self] in self?.updateApp(nil) }
            item.view = view
            updateView = view
            view.update(title: updater.title, enabled: updater.enabled)
            renderedMenu.addItem(item)
        }
        renderedMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AIQuota", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        renderedMenu.addItem(quit)
        // Never empty a menu while it is tracking: removing its last item
        // dismisses it. Attach the new rows before retiring the old rows.
        let nextItems = renderedMenu.items
        for item in nextItems {
            renderedMenu.removeItem(item)
            menu.addItem(item)
        }
        for item in previousItems { menu.removeItem(item) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        Task {
            await store.refresh(userInitiated: true)
            self.rebuild()
        }
    }

    func updateUpdateItem() {
        updateItem?.title = updater?.title ?? ""
        updateItem?.isEnabled = updater?.enabled ?? false
        updateView?.update(title: updater?.title ?? "", enabled: updater?.enabled ?? false)
    }

    @objc private func updateApp(_ sender: Any?) {
        if updater?.title == "Restart and update" { menu.cancelTracking() }
        updater?.activate()
    }

    // MARK: - Sections

    private func addSection(for id: ProviderID, barWidth: CGFloat) {
        let snap = store.snapshot(for: id)
        renderedMenu.addItem(info(headerText(for: id, snap: snap), dimmed: true))
        if let message = snap?.state.message {
            renderedMenu.addItem(info(message, dimmed: true))
            return
        }
        var rows = 0
        rows += addRow(label: "Session", window: snap?.session, barWidth: barWidth)
        rows += addRow(label: "Weekly", window: snap?.weekly, barWidth: barWidth)
        for extra in snap?.extraRows ?? [] {
            rows += addRow(label: extra.label, window: extra.window, barWidth: barWidth)
        }
        if rows == 0 {
            renderedMenu.addItem(info("No usage reported yet", dimmed: true))
        }
    }

    /// One quota row: text line (reset countdown faded inline) plus a
    /// draining bar on its own line below. Returns 1 when rendered.
    @discardableResult
    private func addRow(label: String, window: UsageWindow?, barWidth: CGFloat) -> Int {
        guard let used = window?.usedPercent, let text = rowText(label: label, window: window) else { return 0 }
        let row = info("")
        row.attributedTitle = text
        renderedMenu.addItem(row)
        let barItem = NSMenuItem()
        let view = BarView(
            width: barWidth,
            remaining: 100 - used,
            color: Self.barColor(forRemaining: 100 - used),
            label: label
        )
        barItem.view = view
        renderedMenu.addItem(barItem)
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
    /// while the indicator itself stays aligned with the menu text.
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
        // Longer windows read better as a calendar moment ("resets Sat 3:30 AM"),
        // matching the Claude desktop app.
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(remaining < 6 * 86400 ? "EEE jmm" : "MMM d jmm")
        return "resets \(formatter.string(from: date))"
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
        guard !store.isRefreshing else { return }
        refreshItem?.title = "Refreshing…"
        refreshView?.update(title: "Refreshing…", enabled: false)
        Task {
            await store.refresh(userInitiated: true)
            self.rebuild()
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        onSettings()
    }

    @objc private func quitApp(_ sender: Any?) {
        onQuit()
    }
}

/// AppKit owns capacity rendering; this view only supplies menu insets.
final class BarView: NSView {
    private let indicator = NSLevelIndicator()
    private static let horizontalInset: CGFloat = 16

    init(width: CGFloat, remaining: Double, color: NSColor, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 16))
        autoresizingMask = [.width]
        indicator.levelIndicatorStyle = .continuousCapacity
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.doubleValue = remaining.isFinite ? min(100, max(0, remaining)) : 0
        indicator.isEditable = false
        indicator.drawsTieredCapacityLevels = false
        // Color describes remaining quota (low is a warning), so all
        // native capacity tiers use the same semantic color.
        indicator.fillColor = color
        indicator.warningFillColor = color
        indicator.criticalFillColor = color
        indicator.setAccessibilityLabel("\(label) quota remaining")
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
