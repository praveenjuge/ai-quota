import Foundation

/// Claude: reuses the Claude Code login — macOS Keychain first (Claude Code's
/// source of truth), then ~/.claude/.credentials.json, then
/// $CLAUDE_CONFIG_DIR variants — and calls the OAuth usage endpoint.
/// Read-only: tokens are never refreshed or written back.
enum ClaudeProvider {
    static let id = ProviderID.claude
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!

    struct Credential {
        var accessToken: String
        var expiresAtMs: Double?
        var plan: String?
    }

    static func fetch(allowKeychainPrompt: Bool) async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, plan: nil,
                                    session: UsageWindow(), weekly: UsageWindow(),
                                    state: .ok, fetchedAt: nil)
        let approved: Bool = await MainActor.run { SettingsStore.keychainApproved }
        let keychainGated = !(allowKeychainPrompt || approved)
        let credential: Credential
        do {
            guard let found = try await loadCredential(mayTouchKeychain: !keychainGated,
                                                       promptTimeout: allowKeychainPrompt) else {
                if keychainGated {
                    snap.state = .keychainDenied("Keychain approval needed — click Refresh, then choose Always Allow.")
                } else if Home.env("CLAUDE_CODE_OAUTH_TOKEN") != nil {
                    snap.state = .error("Only a setup-token is set — it can't read usage. Run `claude` to log in.")
                } else {
                    snap.state = .loggedOut("Not logged in — run `claude` once to sign in.")
                }
                return snap
            }
            credential = found
        } catch KeychainError.accessDenied {
            snap.state = .keychainDenied("Keychain approval needed — click Refresh, then choose Always Allow.")
            return snap
        } catch {
            snap.state = .error("Could not read Claude login.")
            return snap
        }
        if let exp = credential.expiresAtMs, exp < Date().timeIntervalSince1970 * 1000 {
            snap.state = .expired("Token expired — use `claude` once to renew it.")
            return snap
        }
        let response: HTTP.Response
        do {
            response = try await HTTP.send(HTTP.get(usageURL, headers: [
                "Authorization": "Bearer \(credential.accessToken)",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-cli/2.1.280 (external, cli)",
            ]))
        } catch {
            snap.state = .transient("Network error — will retry on next refresh.")
            return snap
        }
        switch response.status {
        case 200..<300: break
        case 401, 403:
            await CredentialCache.shared.clearAll()
            snap.state = .expired("Login rejected — run `claude` again to sign in.")
            return snap
        case 429:
            snap.state = .transient("Rate limited by Anthropic — waiting for next refresh.")
            return snap
        case 500...:
            snap.state = .transient("Claude API temporarily unavailable (HTTP \(response.status)).")
            return snap
        default:
            snap.state = .error("Claude API returned HTTP \(response.status).")
            return snap
        }
        guard let body = JSON.object(response.body) else {
            snap.state = .error("Could not parse Claude response.")
            return snap
        }
        snap.plan = credential.plan
        // Newer responses describe every quota in `limits` (the shape the
        // Claude desktop app renders, including model-scoped weekly rows
        // such as "Weekly · Fable"); older ones only carry the fixed
        // five_hour / seven_day windows.
        if !applyLimits(body["limits"], to: &snap) {
            snap.session = window(JSON.dict(body["five_hour"]))
            snap.weekly = window(JSON.dict(body["seven_day"]))
            for (key, model) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                let scoped = window(JSON.dict(body[key]))
                if scoped.usedPercent != nil {
                    snap.extraRows.append(ExtraRow(label: "Weekly · \(model)", window: scoped))
                }
            }
        }
        // Enterprise seats report no session/weekly windows; the monthly
        // extra-usage spend is the quota signal that actually exists.
        if let extra = JSON.dict(body["extra_usage"]),
           let used = JSON.number(extra["utilization"]) {
            snap.extraRows.append(ExtraRow(
                label: "Monthly spend",
                window: UsageWindow(usedPercent: min(100, max(0, used)), resetsAt: nil)
            ))
        }
        snap.fetchedAt = Date()
        return snap
    }

    /// Maps the `limits` array onto the snapshot: the session row and the
    /// unscoped weekly row take the fixed slots; scoped weekly rows (per
    /// model or surface) and unknown groups become labelled extra rows in
    /// the order the API lists them. Returns false when no usable entry
    /// exists so the caller can fall back to the legacy windows.
    static func applyLimits(_ value: Any?, to snap: inout ProviderSnapshot) -> Bool {
        guard let limits = value as? [[String: Any]] else { return false }
        var applied = false
        for limit in limits {
            guard let percent = JSON.number(limit["percent"]) else { continue }
            let window = UsageWindow(usedPercent: min(100, max(0, percent)),
                                     resetsAt: JSON.date(limit["resets_at"]))
            let group = JSON.text(limit["group"]) ?? JSON.text(limit["kind"]) ?? "Other"
            let scopeLabel = scopeText(JSON.dict(limit["scope"]))
            applied = true
            switch (group, scopeLabel) {
            case ("session", nil) where snap.session.usedPercent == nil:
                snap.session = window
            case ("weekly", nil) where snap.weekly.usedPercent == nil:
                snap.weekly = window
            default:
                let base = group.prefix(1).uppercased() + group.dropFirst()
                let label = scopeLabel.map { "\(base) · \($0)" } ?? base
                snap.extraRows.append(ExtraRow(label: label, window: window))
            }
        }
        return applied
    }

    private static func scopeText(_ scope: [String: Any]?) -> String? {
        guard let scope else { return nil }
        var parts: [String] = []
        if let model = JSON.dict(scope["model"]),
           let name = JSON.text(model["display_name"]) ?? JSON.text(model["id"]) {
            parts.append(name)
        }
        if let surface = JSON.dict(scope["surface"]),
           let name = JSON.text(surface["display_name"]) ?? JSON.text(surface["id"]) {
            parts.append(name)
        } else if let surface = JSON.text(scope["surface"]) {
            parts.append(surface)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func window(_ value: [String: Any]?) -> UsageWindow {
        guard let w = value, let used = JSON.number(w["utilization"]) else {
            return UsageWindow()
        }
        return UsageWindow(usedPercent: min(100, max(0, used)),
                           resetsAt: JSON.date(w["resets_at"]))
    }

    /// Keychain first, then file. A tokenless/expired keychain entry falls
    /// through to the file so a fresh `claude` re-login elsewhere still wins.
    /// The Keychain is only touched when allowed (user-initiated, or a prior
    /// grant makes the read silent); the in-memory cache avoids re-reads.
    private static func loadCredential(mayTouchKeychain: Bool, promptTimeout: Bool) async throws -> Credential? {
        let configDir = Home.env("CLAUDE_CONFIG_DIR")
        if mayTouchKeychain {
            for service in keychainServices(configDir: configDir) {
                let cacheKey = "claude:\(service)"
                if let cached = await CredentialCache.shared.get(cacheKey),
                   let cred = parseBlob(cached), cred.accessToken.isEmpty == false,
                   credentialExpired(cred) == false {
                    return cred
                }
                do {
                    if let data = try await Keychain.read(service: service, account: NSUserName(),
                                                          timeout: promptTimeout ? 60 : 10),
                       let cred = parseBlob(data), cred.accessToken.isEmpty == false {
                        if credentialExpired(cred) { continue }
                        await CredentialCache.shared.set(cacheKey, data)
                        await MainActor.run { SettingsStore.keychainApproved = true }
                        return cred
                    }
                } catch KeychainError.accessDenied {
                    throw KeychainError.accessDenied
                } catch { continue }
            }
        }
        let path = configDir.map { "\($0)/.credentials.json" } ?? "~/.claude/.credentials.json"
        let expanded: String = configDir == nil ? (path as NSString).expandingTildeInPath : path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
           let cred = parseBlob(data), cred.accessToken.isEmpty == false,
           credentialExpired(cred) == false {
            return cred
        }
        return nil
    }

    private static func keychainServices(configDir: String?) -> [String] {
        let base = "Claude Code-credentials"
        guard let dir = configDir else { return [base] }
        return ["\(base)-\(shortHash(dir))", base]
    }

    private static func shortHash(_ value: String) -> String {
        // FNV-1a 32-bit, hex. Only used to locate a config-scoped entry;
        // a miss simply falls through to the default service name.
        var hash: UInt32 = 2_166_136_261
        for byte in value.precomposedStringWithCanonicalMapping.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return String(format: "%08x", hash)
    }

    private static func credentialExpired(_ cred: Credential) -> Bool {
        guard let exp = cred.expiresAtMs else { return false }
        return exp < Date().timeIntervalSince1970 * 1000
    }

    /// Parses the credentials document ({claudeAiOauth: {...}}); falls back
    /// to treating the whole blob as a bare token.
    private static func parseBlob(_ data: Data) -> Credential? {
        if let root = JSON.object(data),
           let oauth = JSON.dict(root["claudeAiOauth"]),
           let token = JSON.text(oauth["accessToken"]) {
            var plan: String?
            if let sub = JSON.text(oauth["subscriptionType"]) { plan = sub }
            if let tier = JSON.text(oauth["rateLimitTier"]) {
                plan = [plan, tier].compactMap { $0 }.joined(separator: " · ")
            }
            return Credential(accessToken: token,
                              expiresAtMs: JSON.number(oauth["expiresAt"]),
                              plan: plan)
        }
        if let token = String(data: data, encoding: .utf8).flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines) as String? }),
           !token.isEmpty {
            return Credential(accessToken: token, expiresAtMs: nil, plan: nil)
        }
        return nil
    }
}
