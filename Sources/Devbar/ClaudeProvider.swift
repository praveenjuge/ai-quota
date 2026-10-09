import CryptoKit
import Foundation

/// Claude: reuses a Claude Code login and calls the OAuth usage endpoint.
/// Claude Code keeps one Keychain item per config directory
/// ("Claude Code-credentials" plus "-<hash>" variants, e.g. the one the
/// Claude desktop app's Code tab uses), so every item is considered, newest
/// first, then ~/.claude/.credentials.json.
/// Read-only: tokens are never refreshed or written back, because a
/// refresh rotates the refresh token and would sign Claude Code out.
enum ClaudeProvider {
    static let id = ProviderID.claude
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let keychainService = "Claude Code-credentials"
    private static let approvalMessage = "Keychain approval needed — click Refresh, then choose Always Allow."

    struct Credential {
        var accessToken: String
        var expiresAtMs: Double?
        var scopes: [String]?
        var plan: String?
    }

    /// What the credential search found, so the menu can tell "never signed
    /// in" apart from "signed in, but every token has lapsed".
    enum Lookup {
        case found(Credential)
        case expired
        case mcpOnly
        case missing
    }

    static func fetch(allowKeychainPrompt: Bool) async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, plan: nil,
                                    session: UsageWindow(), weekly: UsageWindow(),
                                    state: .ok, fetchedAt: nil)
        let approved: Bool = await MainActor.run { SettingsStore.keychainApproved }
        let keychainGated = !(allowKeychainPrompt || approved)
        func lookup(rejecting rejected: String? = nil) async -> Lookup? {
            do {
                return try await loadCredential(mayTouchKeychain: !keychainGated,
                                                promptTimeout: allowKeychainPrompt,
                                                rejected: rejected)
            } catch KeychainError.accessDenied {
                snap.state = .keychainDenied(approvalMessage)
            } catch {
                snap.state = .error("Could not read Claude login.")
            }
            return nil
        }
        guard let first = await lookup() else { return snap }
        var credential: Credential
        switch first {
        case .found(let found):
            credential = found
        case _ where keychainGated:
            snap.state = .keychainDenied(approvalMessage)
            return snap
        case .expired:
            snap.state = .expired("Claude login expired — open Claude Code or run `claude` to renew it.")
            return snap
        case .mcpOnly:
            snap.state = .loggedOut("No Claude login found — run `claude` and sign in.")
            return snap
        case .missing:
            if Home.env("CLAUDE_CODE_OAUTH_TOKEN") != nil {
                snap.state = .error("Only a setup-token is set — it can't read usage. Run `claude` to log in.")
            } else {
                snap.state = .loggedOut("Not logged in — run `claude` once to sign in.")
            }
            return snap
        }
        var response: HTTP.Response
        var retried = false
        while true {
            do {
                response = try await HTTP.send(request(usageURL, token: credential.accessToken))
            } catch {
                snap.state = .transient("Network error — will retry on next refresh.")
                return snap
            }
            // A rejected token may have been rotated since it was read; look
            // again once, skipping it, before reporting the login as expired.
            guard [401, 403].contains(response.status), !retried else { break }
            retried = true
            await CredentialCache.shared.clearAll()
            guard case .found(let next)? = await lookup(rejecting: credential.accessToken) else { break }
            credential = next
        }
        switch response.status {
        case 200..<300: break
        case 401, 403:
            snap.state = .expired("Login rejected — open Claude Code or run `claude` to sign in again.")
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
        snap.account = await accountEmail(token: credential.accessToken)
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

    /// Every Claude Code Keychain item, newest first (the $CLAUDE_CONFIG_DIR
    /// one ahead of the rest), then the credentials file. Expired, MCP-only
    /// and usage-less logins are skipped so a fresh login anywhere wins, and
    /// the result still says what was skipped. The Keychain is only touched
    /// when allowed (user-initiated, or a prior grant makes reads silent).
    /// Blobs are cached per item version, so an item Claude Code rewrites is
    /// read again on the next refresh.
    private static func loadCredential(mayTouchKeychain: Bool, promptTimeout: Bool,
                                       rejected: String?) async throws -> Lookup {
        let configDir = Home.env("CLAUDE_CONFIG_DIR")
        var sawExpired = false
        var sawMcpOnly = false
        var denied = false
        func usable(_ data: Data) -> Credential? {
            guard let cred = parseBlob(data) else {
                if isMcpOnly(data) { sawMcpOnly = true }
                return nil
            }
            guard hasUsageScope(cred) else { return nil }
            if cred.accessToken == rejected || credentialExpired(cred) {
                sawExpired = true
                return nil
            }
            return cred
        }
        if mayTouchKeychain {
            for item in keychainItems(configDir: configDir) {
                let cacheKey = "claude:\(item.service):\(item.modified.timeIntervalSince1970)"
                let data: Data
                if let cached = await CredentialCache.shared.get(cacheKey) {
                    data = cached
                } else {
                    do {
                        guard let read = try await Keychain.read(service: item.service, account: NSUserName(),
                                                                 timeout: promptTimeout ? 60 : 10) else { continue }
                        data = read
                    } catch KeychainError.accessDenied {
                        denied = true
                        continue
                    } catch { continue }
                    await CredentialCache.shared.set(cacheKey, data)
                    await MainActor.run { SettingsStore.keychainApproved = true }
                }
                if let cred = usable(data) { return .found(cred) }
            }
        }
        let path = configDir.map { "\($0)/.credentials.json" } ?? "~/.claude/.credentials.json"
        let expanded: String = configDir == nil ? (path as NSString).expandingTildeInPath : path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)), let cred = usable(data) {
            return .found(cred)
        }
        if denied { throw KeychainError.accessDenied }
        if sawExpired { return .expired }
        return sawMcpOnly ? .mcpOnly : .missing
    }

    /// Claude Code names its items "Claude Code-credentials", plus "-" and
    /// the first 8 hex digits of SHA-256(config dir) for a non-default dir
    /// (the Claude desktop app uses its own). Listing reads attributes only.
    private static func keychainItems(configDir: String?) -> [KeychainItem] {
        var items = Keychain.items(servicePrefix: keychainService, account: NSUserName())
            .filter { $0.service == keychainService || isScopedService($0.service) }
        if items.isEmpty {
            items = [KeychainItem(service: keychainService, modified: .distantPast)]
        }
        if let dir = configDir {
            let scoped = "\(keychainService)-\(configHash(dir))"
            let match = items.first { $0.service == scoped } ?? KeychainItem(service: scoped, modified: .distantPast)
            items.removeAll { $0.service == scoped }
            items.insert(match, at: 0)
        }
        return items
    }

    private static func isScopedService(_ service: String) -> Bool {
        let suffix = service.dropFirst(keychainService.count + 1)
        return service.hasPrefix(keychainService + "-") && suffix.count == 8
            && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func configHash(_ dir: String) -> String {
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    private static func credentialExpired(_ cred: Credential) -> Bool {
        guard let exp = cred.expiresAtMs else { return false }
        return exp < Date().timeIntervalSince1970 * 1000
    }

    /// The usage endpoint needs `user:profile`; inference-only tokens 403.
    private static func hasUsageScope(_ cred: Credential) -> Bool {
        cred.scopes.map { $0.contains("user:profile") } ?? true
    }

    /// Claude Code 2.x may store only MCP server logins in an item.
    private static func isMcpOnly(_ data: Data) -> Bool {
        guard let root = JSON.object(data) else { return false }
        return root["claudeAiOauth"] == nil && root["mcpOAuth"] != nil
    }

    /// The email of the login actually in use. Several logins may exist
    /// (CLI, desktop app), so it comes from the token, not a config file.
    /// Cached per token; a failed lookup only leaves the header without it.
    private static func accountEmail(token: String) async -> String? {
        let cacheKey = "claude-email:" + SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = await CredentialCache.shared.get(cacheKey) {
            return String(decoding: cached, as: UTF8.self)
        }
        guard let response = try? await HTTP.send(request(profileURL, token: token)),
              (200..<300).contains(response.status),
              let account = JSON.object(response.body).flatMap({ JSON.dict($0["account"]) }),
              let email = JSON.text(account["email"]) ?? JSON.text(account["email_address"]) else { return nil }
        await CredentialCache.shared.set(cacheKey, Data(email.utf8))
        return email
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        HTTP.get(url, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.280 (external, cli)",
        ])
    }

    /// "team" + "default_claude_max_5x" reads as "Team · Max 5x"; a Max
    /// plan is just "Max 5x". Default tiers add nothing and are dropped.
    static func planName(subscription: String?, tier: String?) -> String? {
        let plan = subscription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        guard let tier, let range = tier.range(of: #"max_\d+x$"#, options: .regularExpression) else {
            return plan
        }
        let usage = "Max " + tier[range].dropFirst("max_".count)
        guard let plan, !usage.hasPrefix(plan) else { return usage }
        return "\(plan) · \(usage)"
    }

    /// Parses the credentials document ({claudeAiOauth: {...}}); a blob that
    /// is not JSON is treated as a bare token.
    private static func parseBlob(_ data: Data) -> Credential? {
        if let root = JSON.object(data) {
            guard let oauth = JSON.dict(root["claudeAiOauth"]),
                  let token = JSON.text(oauth["accessToken"]) else { return nil }
            return Credential(accessToken: token,
                              expiresAtMs: JSON.number(oauth["expiresAt"]),
                              scopes: oauth["scopes"] as? [String],
                              plan: planName(subscription: JSON.text(oauth["subscriptionType"]),
                                             tier: JSON.text(oauth["rateLimitTier"])))
        }
        if let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return Credential(accessToken: token, expiresAtMs: nil, scopes: nil, plan: nil)
        }
        return nil
    }
}
