import AppKit

/// Native status-item menu (Battery-menu style): provider sections with
/// quota rows, then Refresh / Settings / Quit. All rows are stock menu
/// items: section headers, badged rows with subtitles, plus native
/// capacity indicators on their own lines.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private var renderedMenu = NSMenu()
    private let store: UsageStore
    private let updater: UpdateController?
    private var updateItem: NSMenuItem?
    private var refreshItem: NSMenuItem?
    private let caffeinate = Caffeinate()
    private let onCaffeinateChange: (Bool) -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(
        store: UsageStore,
        updater: UpdateController?,
        onCaffeinateChange: @escaping (Bool) -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.updater = updater
        self.onCaffeinateChange = onCaffeinateChange
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()
        menu.delegate = self
        // Explicit enabled states (auto-validation would re-enable
        // actionless rows, defeating the dimmed style).
        menu.autoenablesItems = false
        // Bars stretch to the menu width; this keeps them from getting stubby.
        menu.minimumWidth = Self.minimumWidth
        rebuild()
    }

    static let minimumWidth: CGFloat = 240

    /// Rebuild items from the latest snapshots (cheap, synchronous).
    func rebuild() {
        let previousItems = menu.items
        renderedMenu = NSMenu()
        let enabled = ProviderID.allCases.filter { SettingsStore.isEnabled($0) }
        for (index, id) in enabled.enumerated() {
            if index > 0 { renderedMenu.addItem(.separator()) }
            addSection(for: id)
        }
        renderedMenu.addItem(.separator())
        let refresh = NSMenuItem(
            title: store.isRefreshing ? "Refreshing…" : "Refresh",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refresh.target = self
        refresh.isEnabled = !store.isRefreshing
        setDetail(store.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }, on: refresh)
        refreshItem = refresh
        renderedMenu.addItem(refresh)
        let caffeinateItem = NSMenuItem(title: "Caffeinate", action: #selector(toggleCaffeinate), keyEquivalent: "")
        caffeinateItem.target = self
        caffeinateItem.state = caffeinate.isOn ? .on : .off
        renderedMenu.addItem(caffeinateItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        renderedMenu.addItem(settings)
        if let updater {
            let item = NSMenuItem(title: updater.title, action: #selector(updateApp), keyEquivalent: "")
            item.target = self
            item.isEnabled = updater.enabled
            updateItem = item
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
    }

    @objc private func updateApp(_ sender: Any?) {
        updater?.activate()
    }

    // MARK: - Sections

    private func addSection(for id: ProviderID) {
        let snap = store.snapshot(for: id)
        renderedMenu.addItem(.sectionHeader(title: headerText(for: id, snap: snap)))
        if let message = snap?.state.message {
            renderedMenu.addItem(info(message, dimmed: true))
            return
        }
        var rows = 0
        rows += addRow(label: "Session", window: snap?.session)
        rows += addRow(label: "Weekly", window: snap?.weekly)
        for extra in snap?.extraRows ?? [] {
            rows += addRow(label: extra.label, window: extra.window)
        }
        if rows == 0 {
            renderedMenu.addItem(info("No usage reported yet", dimmed: true))
        }
    }

    /// One quota row: label with the remaining percentage as a badge and
    /// the reset time as subtitle, plus a draining bar on its own line
    /// below. Returns 1 when rendered.
    @discardableResult
    private func addRow(label: String, window: UsageWindow?) -> Int {
        guard let remaining = window?.remainingPercent else { return 0 }
        let row = info(label)
        row.badge = NSMenuItemBadge(string: "\((remaining / 100).formatted(.percent.precision(.fractionLength(0)))) left")
        setDetail(resetText(window?.resetsAt), on: row)
        renderedMenu.addItem(row)
        let barItem = NSMenuItem()
        barItem.view = BarView(remaining: remaining, label: label)
        renderedMenu.addItem(barItem)
        return 1
    }

    private func headerText(for id: ProviderID, snap: ProviderSnapshot?) -> String {
        var header = id.displayName
        if let plan = snap?.plan { header += " · \(plan)" }
        return header
    }

    /// Secondary line under the title. Subtitles need macOS 14.4, so older
    /// systems fold the detail into the title instead.
    private func setDetail(_ detail: String?, on item: NSMenuItem) {
        guard let detail else { return }
        if #available(macOS 14.4, *) {
            item.subtitle = detail
        } else {
            item.title += " · \(detail)"
        }
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
        if remaining <= 0 { return "Resetting…" }
        if remaining < 86400 {
            let duration = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            return "Resets in \(duration)"
        }
        // Longer windows read better as a calendar moment ("Resets Sat 3:30 AM"),
        // matching the Claude desktop app.
        let style: Date.FormatStyle = remaining < 6 * 86400
            ? .dateTime.weekday(.abbreviated).hour().minute()
            : .dateTime.month(.abbreviated).day().hour().minute()
        return "Resets \(date.formatted(style))"
    }

    // MARK: - Actions

    @objc private func noop(_ sender: Any?) {}

    @objc private func refreshNow(_ sender: Any?) {
        guard !store.isRefreshing else { return }
        refreshItem?.title = "Refreshing…"
        refreshItem?.isEnabled = false
        Task {
            await store.refresh(userInitiated: true)
            self.rebuild()
        }
    }

    @objc private func toggleCaffeinate(_ sender: Any?) {
        caffeinate.toggle()
        onCaffeinateChange(caffeinate.isOn)
        rebuild()
    }

    @objc private func openSettings(_ sender: Any?) {
        onSettings()
    }

    @objc private func quitApp(_ sender: Any?) {
        onQuit()
    }
}

/// AppKit owns capacity rendering and color; this view only supplies menu
/// insets. Its flexible width lets the menu stretch it to the menu width.
final class BarView: NSView {
    private let indicator = NSLevelIndicator()
    private static let horizontalInset: CGFloat = 16

    init(remaining: Double, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenu.minimumWidth, height: 16))
        autoresizingMask = [.width]
        indicator.levelIndicatorStyle = .continuousCapacity
        indicator.minValue = 0
        indicator.maxValue = 100
        // A critical value below the warning value flags low levels, like
        // Battery: green normally, yellow under 25%, red under 10%.
        indicator.warningValue = 25
        indicator.criticalValue = 10
        indicator.doubleValue = remaining.isFinite ? min(100, max(0, remaining)) : 0
        indicator.isEditable = false
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
