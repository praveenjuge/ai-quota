import Foundation

/// Codex: reuses the Codex CLI login in $CODEX_HOME/auth.json (or
/// ~/.codex/auth.json) and calls the CLI's own usage endpoint.
/// Read-only: the token is never refreshed — refreshing would rotate the
/// single-use refresh token and log the user out of the Codex CLI.
enum CodexProvider {
    static let id = ProviderID.codex
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let sessionSeconds = 18_000.0 // 5h
    private static let weeklySeconds = 604_800.0 // 7d

    static func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, plan: nil,
                                    session: UsageWindow(), weekly: UsageWindow(),
                                    state: .ok, fetchedAt: nil)
        guard let data = authFile(),
              let root = JSON.object(data),
              let tokens = JSON.dict(root["tokens"]),
              let accessToken = JSON.text(tokens["access_token"]) else {
            snap.state = .loggedOut("Not logged in — run `codex` once to sign in.")
            return snap
        }
        snap.account = JSON.text(JSON.text(tokens["id_token"]).flatMap(claims)?["email"])
        if tokenExpired(accessToken) {
            snap.state = .expired("Token expired — use `codex` once to renew it.")
            return snap
        }
        var headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
        if let accountID = JSON.text(tokens["account_id"]) {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let response: HTTP.Response
        do {
            response = try await HTTP.send(HTTP.get(usageURL, headers: headers))
        } catch {
            snap.state = .transient("Network error — will retry on next refresh.")
            return snap
        }
        switch response.status {
        case 200..<300: break
        case 401, 403:
            snap.state = .expired("Login rejected — use `codex` once to renew it.")
            return snap
        case 429:
            snap.state = .transient("Rate limited — will retry on next refresh.")
            return snap
        case 500...:
            snap.state = .transient("Codex API temporarily unavailable (HTTP \(response.status)).")
            return snap
        default:
            snap.state = .error("Codex API returned HTTP \(response.status).")
            return snap
        }
        guard let body = JSON.object(response.body) else {
            snap.state = .error("Could not parse Codex response.")
            return snap
        }
        snap.plan = JSON.text(body["plan_type"])?.capitalized
        if let rateLimit = JSON.dict(body["rate_limit"]) {
            let primary = JSON.dict(rateLimit["primary_window"])
            let secondary = JSON.dict(rateLimit["secondary_window"])
            snap.session = classify(window: primary, fallback: .session,
                                    other: secondary)
            snap.weekly = classify(window: secondary, fallback: .weekly,
                                   other: primary)
        }
        snap.fetchedAt = Date()
        return snap
    }

    private enum Kind { case session, weekly }

    /// Classify by limit_window_seconds when present, else by position
    /// (primary = session, secondary = weekly).
    private static func classify(window: [String: Any]?, fallback: Kind,
                                 other: [String: Any]?) -> UsageWindow {
        let kindOf: ([String: Any]?) -> Kind? = { w in
            guard let s = JSON.number(w?["limit_window_seconds"]) else { return nil }
            if s == sessionSeconds { return .session }
            if s == weeklySeconds { return .weekly }
            return nil
        }
        let chosen: [String: Any]?
        if kindOf(window) == fallback || (kindOf(window) == nil && kindOf(other) != fallback) {
            chosen = window
        } else if kindOf(other) == fallback {
            chosen = other
        } else {
            chosen = window
        }
        guard let w = chosen, let used = JSON.number(w["used_percent"]) else {
            return UsageWindow()
        }
        var resetsAt: Date?
        if let at = JSON.number(w["reset_at"]) {
            resetsAt = Date(timeIntervalSince1970: at)
        } else if let after = JSON.number(w["reset_after_seconds"]) {
            resetsAt = Date().addingTimeInterval(after)
        }
        return UsageWindow(usedPercent: min(100, max(0, used)), resetsAt: resetsAt)
    }

    private static func authFile() -> Data? {
        if let home = Home.env("CODEX_HOME") {
            return try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
        }
        return Home.file("~/.codex/auth.json")
    }

    /// Local JWT expiry check. Undecodable or missing exp never fails —
    /// the usage call itself is the real test.
    private static func tokenExpired(_ token: String) -> Bool {
        guard let exp = JSON.number(claims(token)?["exp"]) else { return false }
        return exp < Date().timeIntervalSince1970 + 60
    }

    /// Decodes a JWT payload without verifying it (display and expiry only).
    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload).flatMap(JSON.object)
    }
}
