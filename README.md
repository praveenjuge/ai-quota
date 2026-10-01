# AIQuota

Native macOS menu-bar app showing remaining AI quota for Codex, Claude, and Muse Code. Icon-only in the menu bar; click for a native menu with draining quota bars.

## Requirements

- macOS 14+
- Existing logins: Codex CLI (`~/.codex/auth.json`), Claude Code (Keychain), Muse (`~/.config/muse/auth.json` or Keychain)

## Build & run

```sh
swift build                                    # debug build
.build/debug/AIQuota --dump-usage              # headless JSON check
./build-app.sh                                 # signed release bundle -> dist/AIQuota.app
open dist/AIQuota.app
```

Set `CODESIGN_IDENTITY` to override the signing identity used by `build-app.sh`; when the identity isn't on the keychain it falls back to an ad-hoc signature.

## How it works

- Pure Swift/SwiftUI + AppKit, no dependencies. `LSUIElement` accessory app.
- Reuses CLI logins read-only; tokens are never refreshed or written back.
  - Codex: `~/.codex/auth.json` → `GET chatgpt.com/backend-api/wham/usage`
  - Claude: Keychain `Claude Code-credentials` (fallback: `~/.claude/.credentials.json`) → `GET api.anthropic.com/api/oauth/usage`
  - Muse: `~/.config/muse/auth.json` or Keychain `ai.meta.dev.credentials/meta` → `POST api.meta.ai/muse-code/key` (minted key is discarded)
- Keychain is read via the `/usr/bin/security` subprocess (stable attribution, so one Always Allow sticks), blobs are cached in memory, and background refreshes never prompt.
- Refreshes every 10 minutes and whenever the menu opens. Transient failures (network, 429, 5xx) keep last-good data; durable ones (logout, expired) replace it.
- Menu rows are stock `NSMenuItem`s; each bar is a bar-only `NSView` that stretches to the full menu width, so bars span edge to edge under the key-hint column.

## Releases

Every push to `main` builds on Apple Silicon runners, bumps the patch version tag (`v0.1.0`, `v0.1.1`, …), and publishes `.zip`, `.dmg`, and `.pkg` artifacts. The app and DMG are signed and notarized. The PKG is signed and notarized only when a Developer ID Installer certificate is configured; otherwise it contains the notarized app but is unsigned and does not pass Gatekeeper's installer assessment. The tag is created only after successful packaging.

CI needs these repository secrets (`gh secret set NAME --repo praveenjuge/ai-quota`):

| Secret | Value |
|---|---|
| `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64` | Base64 of the Developer ID Application `.p12` (Keychain Access → My Certificates → right-click → Export) |
| `APPLE_DEVELOPER_CERTIFICATE_PASSWORD` | Password set when exporting the `.p12` |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password from appleid.apple.com |
| `APPLE_INSTALLER_CERTIFICATE_P12_BASE64` | (Optional) Base64 of a Developer ID Installer `.p12` — without it the PKG ships unsigned |
| `APPLE_INSTALLER_CERTIFICATE_PASSWORD` | (Optional) Its export password — defaults to the app cert password |

```sh
base64 -i /path/to/dev-id-app.p12 | gh secret set APPLE_DEVELOPER_CERTIFICATE_P12_BASE64
gh secret set APPLE_DEVELOPER_CERTIFICATE_PASSWORD   # paste .p12 password
gh secret set APPLE_ID                               # paste Apple ID email
gh secret set APPLE_APP_SPECIFIC_PASSWORD            # paste app-specific password
```

## Settings

Provider toggles, launch at login (`SMAppService`), and Quit. Preferences are stored via `UserDefaults` (`provider.<id>.enabled`, `keychainApproved`).
