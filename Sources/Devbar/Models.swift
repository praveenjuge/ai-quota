import Foundation

enum ProviderID: String, CaseIterable, Sendable {
    case codex
    case claude
    case muse

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .muse: "Muse"
        }
    }
}

/// One rolling quota window. All values optional: a missing window means the
/// vendor did not report it (idle window, unknown shape) — never a crash.
struct UsageWindow: Sendable {
    var usedPercent: Double?
    var resetsAt: Date?

    var remainingPercent: Double? {
        usedPercent.map { max(0, 100 - $0) }
    }
}

enum ProviderState: Sendable {
    /// Fresh data (windows may still be individually nil).
    case ok
    /// No login found on this Mac.
    case loggedOut(String)
    /// Login exists but the token is expired/rejected; the CLI must renew it.
    case expired(String)
    /// Keychain item exists but this app may not read it yet.
    case keychainDenied(String)
    /// Durable failure (bad response shape, no subscription, rejected call).
    case error(String)
    /// Transient failure (network blip, rate limit, vendor 5xx): keeps
    /// last-good data instead of replacing it.
    case transient(String)

    var message: String? {
        switch self {
        case .ok: return nil
        case .loggedOut(let m), .expired(let m), .keychainDenied(let m),
             .error(let m), .transient(let m): return m
        }
    }

    var isOk: Bool {
        if case .ok = self { return true }
        return false
    }

    var isTransient: Bool {
        if case .transient = self { return true }
        return false
    }
}

struct ExtraRow: Sendable {
    var label: String
    var window: UsageWindow
}

struct ProviderSnapshot: Sendable {
    var id: ProviderID
    var plan: String?
    var session: UsageWindow
    var weekly: UsageWindow
    var extraRows: [ExtraRow] = []
    var state: ProviderState
    var fetchedAt: Date?
}
