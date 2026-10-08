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

    static func key(for id: ProviderID) -> String {
        "provider.\(id.rawValue).enabled"
    }

    /// True once a user-initiated Keychain read has succeeded, meaning macOS
    /// granted access and later reads are silent. Background refreshes only
    /// touch the Keychain when this is set, so they can never prompt.
    static var keychainApproved: Bool {
        get { defaults.bool(forKey: "keychain.approved") }
        set { defaults.set(newValue, forKey: "keychain.approved") }
    }

    /// On once registered, even while macOS still waits for approval.
    static var launchAtLogin: Bool {
        get { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
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

    /// Registered, but the user still has to allow it in System Settings.
    static var launchAtLoginNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
