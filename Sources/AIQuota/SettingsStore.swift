import Foundation
import ServiceManagement

/// Minimal persisted settings: one on/off toggle per provider plus
/// launch-at-login. Backed by UserDefaults; no custom UI anywhere.
@MainActor
enum SettingsStore {
    private static let defaults = UserDefaults.standard

    static func isEnabled(_ id: ProviderID) -> Bool {
        defaults.object(forKey: key(for: id)) as? Bool ?? true
    }

    static func setEnabled(_ id: ProviderID, _ value: Bool) {
        defaults.set(value, forKey: key(for: id))
    }

    private static func key(for id: ProviderID) -> String {
        "provider.\(id.rawValue).enabled"
    }

    /// True once a user-initiated Keychain read has succeeded, meaning macOS
    /// granted access and later reads are silent. Background refreshes only
    /// touch the Keychain when this is set, so they can never prompt.
    static var keychainApproved: Bool {
        get { defaults.bool(forKey: "keychain.approved") }
        set { defaults.set(newValue, forKey: "keychain.approved") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Launch-at-login needs a bundled app identity; a bare binary
                // throws here and the toggle simply stays off.
            }
        }
    }
}
