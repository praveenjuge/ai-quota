import Foundation
import os

/// Holds the latest snapshot per provider, refreshes on a timer and on
/// demand. Stale-while-revalidate: the UI always shows the last good data
/// instantly while a refresh runs in the background.
@MainActor
@Observable
final class UsageStore {
    static let refreshInterval: TimeInterval = {
        // DEVBAR_REFRESH_SECONDS overrides the 10-minute default (testing).
        if let raw = Home.env("DEVBAR_REFRESH_SECONDS"),
           let seconds = TimeInterval(raw), seconds >= 10 {
            return seconds
        }
        return 600
    }()

    private static let log = Logger(subsystem: "com.praveenjuge.devbar", category: "refresh")

    var snapshots: [ProviderID: ProviderSnapshot] = [:]
    var isRefreshing = false
    var lastRefresh: Date?

    func snapshot(for id: ProviderID) -> ProviderSnapshot? {
        snapshots[id]
    }

    /// Refreshes all enabled providers concurrently. Concurrent calls merge:
    /// a refresh already in flight is not started twice.
    /// Only user-initiated refreshes (popover open, Refresh button) may show
    /// a Keychain approval prompt; timer refreshes stay silent.
    func refresh(userInitiated: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        Self.log.info("refresh started userInitiated=\(userInitiated)")
        let enabled = ProviderID.allCases.filter { SettingsStore.isEnabled($0) }
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            for id in enabled {
                group.addTask {
                    switch id {
                    case .codex: await CodexProvider.fetch()
                    case .claude: await ClaudeProvider.fetch(allowKeychainPrompt: userInitiated)
                    case .muse: await MuseProvider.fetch(allowKeychainPrompt: userInitiated)
                    }
                }
            }
            for await snap in group {
                // A transient failure never wipes last-good data (e.g. a
                // 429 keeps showing the previous numbers); durable state
                // changes (logout, expiry, no subscription) always replace.
                if snap.state.isOk || self.snapshots[snap.id] == nil || !snap.state.isTransient {
                    self.snapshots[snap.id] = snap
                }
                if let message = snap.state.message {
                    Self.log.info("\(snap.id.rawValue): \(message)")
                } else {
                    Self.log.info("\(snap.id.rawValue): ok")
                }
            }
        }
        lastRefresh = Date()
        Self.log.info("refresh finished")
    }
}
