import Foundation

/// Muse: reuses the `muse login` device-code credential — an inline token in
/// ~/.config/muse/auth.json when present, else the Keychain item
/// ai.meta.dev.credentials / meta (a JSON blob whose access_token is the
/// dca: token) — and calls the same subscription endpoint the CLI uses at
/// startup. The minted inference key in the response is discarded.
enum MuseProvider {
    static let id = ProviderID.muse
    private static let keyURL = URL(string: "https://api.meta.ai/muse-code/key")!

    static func fetch(allowKeychainPrompt: Bool) async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, plan: nil,
                                    session: UsageWindow(), weekly: UsageWindow(),
                                    state: .ok, fetchedAt: nil)
        let approved: Bool = await MainActor.run { SettingsStore.keychainApproved }
        let keychainGated = !(allowKeychainPrompt || approved)
        let token: String
        do {
            guard let found = try await loadToken(mayTouchKeychain: !keychainGated,
                                                  promptTimeout: allowKeychainPrompt) else {
                if keychainGated {
                    snap.state = .keychainDenied("Keychain approval needed — click Refresh, then choose Always Allow.")
                } else {
                    snap.state = .loggedOut("Not logged in — run `muse login` once.")
                }
                return snap
            }
            token = found
        } catch KeychainError.accessDenied {
            snap.state = .keychainDenied("Keychain approval needed — click Refresh, then choose Always Allow.")
            return snap
        } catch {
            snap.state = .error("Could not read Muse login.")
            return snap
        }
        guard token.hasPrefix("dca:") else {
            snap.state = .error("Unexpected login format — run `muse login` again.")
            return snap
        }
        let response: HTTP.Response
        do {
            response = try await HTTP.send(HTTP.postJSON(keyURL, headers: [
                "Authorization": "Bearer \(token)",
                "x-api-version": "1.0.0",
            ]))
        } catch {
            snap.state = .transient("Network error — will retry on next refresh.")
            return snap
        }
        switch response.status {
        case 200..<300: break
        case 401, 403:
            await CredentialCache.shared.clearAll()
            snap.state = .expired("Login rejected — run `muse login` again.")
            return snap
        case 429:
            snap.state = .transient("Rate limited — will retry on next refresh.")
            return snap
        case 500...:
            snap.state = .transient("Muse API temporarily unavailable (HTTP \(response.status)).")
            return snap
        default:
            snap.state = .error("Muse API returned HTTP \(response.status).")
            return snap
        }
        guard let body = JSON.object(response.body) else {
            snap.state = .error("Could not parse Muse response.")
            return snap
        }
        if body["require_payment"] as? Bool == true {
            snap.state = .error("A payment method is required — finish billing at dev.meta.ai.")
            return snap
        }
        guard body["is_subs_active"] as? Bool == true else {
            snap.state = .error("No active Muse subscription on this login.")
            return snap
        }
        snap.plan = JSON.text(body["subs_tier_name"])
        // Meta omits subs_usage while the 5h window is idle. Keep plan and
        // identity; the rows simply show no data until usage appears.
        if let usage = JSON.dict(body["subs_usage"]) {
            snap.session = window(JSON.dict(usage["window"]))
            snap.weekly = window(JSON.dict(usage["weekly"]))
        }
        snap.fetchedAt = Date()
        return snap
    }

    private static func window(_ value: [String: Any]?) -> UsageWindow {
        guard let w = value, let used = JSON.number(w["used_percent"]) else {
            return UsageWindow()
        }
        return UsageWindow(usedPercent: min(100, max(0, used)),
                           resetsAt: JSON.date(w["resets_at"]))
    }

    private static func loadToken(mayTouchKeychain: Bool, promptTimeout: Bool) async throws -> String? {
        let path: String
        if let override = Home.env("MUSE_AUTH_PATH") {
            path = override
        } else if let xdg = Home.env("XDG_CONFIG_HOME") {
            path = "\(xdg)/muse/auth.json"
        } else {
            path = ("~/.config/muse/auth.json" as NSString).expandingTildeInPath
        }
        var inline: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let root = JSON.object(data),
           let providers = JSON.dict(root["providers"]),
           let meta = JSON.dict(providers["meta"]) {
            inline = JSON.text(meta["access_token"])
        }
        if let inline, !inline.isEmpty { return inline }
        guard mayTouchKeychain else { return nil }
        let cacheKey = "muse:ai.meta.dev.credentials"
        if let cached = await CredentialCache.shared.get(cacheKey),
           let token = parseBlob(cached) {
            return token
        }
        do {
            guard let data = try await Keychain.read(service: "ai.meta.dev.credentials", account: "meta",
                                                     timeout: promptTimeout ? 60 : 10) else {
                return nil
            }
            guard let token = parseBlob(data) else { return nil }
            await CredentialCache.shared.set(cacheKey, data)
            await MainActor.run { SettingsStore.keychainApproved = true }
            return token
        } catch KeychainError.accessDenied {
            throw KeychainError.accessDenied
        } catch {
            return nil
        }
    }

    /// The item is usually {secret_schema_version, api_key, access_token};
    /// accept a bare dca: token too.
    private static func parseBlob(_ data: Data) -> String? {
        if let root = JSON.object(data),
           let token = JSON.text(root["access_token"]) {
            return token
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
