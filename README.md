# AIQuota

Native macOS menu-bar app showing remaining AI quota for Codex, Claude, and Muse Code. Icon-only in the menu bar; click for a native menu with draining quota bars and the dev servers running on your Mac.

## Requirements

- macOS 14+
- Existing logins: Codex CLI (`~/.codex/auth.json`), Claude Code (Keychain), Muse (`~/.config/muse/auth.json` or Keychain)

## Build & run

```sh
swift build                                    # debug build
.build/debug/AIQuota --dump-usage              # headless JSON check
.build/debug/AIQuota --dump-ports              # detected dev servers as JSON
./build-app.sh                                 # signed release bundle -> dist/AIQuota.app
open dist/AIQuota.app
```

Set `CODESIGN_IDENTITY` to override the Developer ID signing identity used by `build-app.sh`. Release bundles require a valid signing identity.

## How it works

- Swift/SwiftUI + AppKit, with Sparkle for updates. `LSUIElement` accessory app.
- Reuses CLI logins read-only; tokens are never refreshed or written back.
  - Codex: `~/.codex/auth.json` → `GET chatgpt.com/backend-api/wham/usage`
  - Claude: newest valid Keychain `Claude Code-credentials` item, including the `-<hash>` items Claude Code keeps per config folder (such as the Claude desktop app's), then `~/.claude/.credentials.json` → `GET api.anthropic.com/api/oauth/usage`. Tokens are never refreshed, so Claude Code's own logins are never rotated out from under it.
  - Muse: `~/.config/muse/auth.json` or Keychain `ai.meta.dev.credentials/meta` → `POST api.meta.ai/muse-code/key` (minted key is discarded)
- Keychain is read via the `/usr/bin/security` subprocess (stable attribution, so one Always Allow sticks), blobs are cached in memory, and background refreshes never prompt.
- Refreshes every 10 minutes and whenever the menu opens. Transient failures (network, 429, 5xx) keep last-good data; durable ones (logout, expired) replace it.
- Menu rows are stock `NSMenuItem`s: section headers per provider, quota rows with the remaining percentage as a badge and the reset time as subtitle. Each quota bar is a native `NSLevelIndicator` inside a resizing menu view, inset to align with the menu text; AppKit colors it (yellow under 25%, red under 10%).

## Dev Servers

The menu lists TCP ports that dev servers are listening on (`lsof -nP -iTCP -sTCP:LISTEN`), scanned each time the menu opens. A listener counts as a dev server when its process was started from a project folder: system services and apps, which launchd starts in `/` or inside their app bundle, are left out. Each row shows `localhost:<port>` with the project folder and process name; its submenu opens it in the browser, copies the URL or PID, hides that process name, or stops the process (`SIGTERM`, or `SIGKILL` as Force Stop while holding ⌥).

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

Provider toggles, Show dev servers (with a list of hidden processes to restore), launch at login (`SMAppService`, with a link to Login Items when macOS needs approval), and Quit. Preferences are stored via `UserDefaults` (`provider.<id>.enabled`, `devServers.enabled`, `devServers.hidden`, `keychainApproved`).

## Automatic updates

Release `.app` bundles use Sparkle 2.10.0. They check at startup and every six
hours, download verified updates in the background, and show update status below
Settings. Choose **Restart and update**, or quit normally to install for the next
launch. Debug builds and `--dump-usage` do not start the updater. No credentials or
system profile are sent to the update feed.

Only the stable GitHub release marked **Latest** is offered. Each release includes
a signed `appcast.xml` and a signed, notarized ARM64 ZIP; equal or older versions
are ignored. Existing installations without Sparkle need one manual upgrade.

`bash build-app.sh 0.1.3` sets both bundle version fields. Omit the argument to use
the nearest release tag. Builds require the Developer ID signing identity and a
fresh output path; set `APP_OUTPUT` to retain an existing bundle. Local and CI
bundles use the same assembler, including Sparkle framework/helper signing.

The update key is stored in the login Keychain under the `ai-quota` account.
CI also requires `SPARKLE_PRIVATE_KEY`. Its public key is in `Resources/Info.plist`.
Never commit or log the private key. To restore CI access from this Mac:

```sh
security find-generic-password -a ai-quota -s https://sparkle-project.org -w \
  | gh secret set SPARKLE_PRIVATE_KEY --repo praveenjuge/ai-quota
```

CI generates and signs the feed after notarization, uploads all four assets to a
draft release, verifies the asset list, then publishes it as Latest. The app
requires a signed feed and verifies archive signatures before extraction.

### Verify updates locally

```sh
APP_OUTPUT=dist/e2e-source/AIQuota.app bash build-app.sh 0.1.3
python3 scripts/verify-updates.py dist/e2e-source/AIQuota.app
```

This requires Interceptor with Accessibility permission and the Keychain update
key. It prepares signed app copies with unique test identities, uses a localhost
signed feed, and checks clicked restart, normal Quit, preference preservation,
and rejection of invalid feeds/archives. Results are saved in
`dist/verification/update-e2e.json`; each result links retained menu trees and
app logs. Production apps and preferences are untouched.

Refresh and Check for updates are stock menu items, so clicking them closes the
menu like any system menu. Reopen it to see **Refreshing…** or the update result.

To verify menu tracking with the canonical menu implementation:

```sh
bash scripts/verify-menu-feedback.sh dist/e2e-source/AIQuota.app
```

The signed test host opens the menu, asserts it stays open while the refresh
rebuilds it, then checks for updates and asserts the result shows when the menu
reopens. Results are retained.
