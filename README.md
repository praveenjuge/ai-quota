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

Set `CODESIGN_IDENTITY` to override the signing identity used by `build-app.sh`.

## How it works

- Pure Swift/SwiftUI + AppKit, no dependencies. `LSUIElement` accessory app.
- Reuses CLI logins read-only; tokens are never refreshed or written back.
  - Codex: `~/.codex/auth.json` → `GET chatgpt.com/backend-api/wham/usage`
  - Claude: Keychain `Claude Code-credentials` (fallback: `~/.claude/.credentials.json`) → `GET api.anthropic.com/api/oauth/usage`
  - Muse: `~/.config/muse/auth.json` or Keychain `ai.meta.dev.credentials/meta` → `POST api.meta.ai/muse-code/key` (minted key is discarded)
- Keychain is read via the `/usr/bin/security` subprocess (stable attribution, so one Always Allow sticks), blobs are cached in memory, and background refreshes never prompt.
- Refreshes every 10 minutes and whenever the menu opens. Transient failures (network, 429, 5xx) keep last-good data; durable ones (logout, expired) replace it.
- Menu rows are stock `NSMenuItem`s; each bar is a bar-only `NSView` that stretches to the full menu width, so bars span edge to edge under the key-hint column.

## Settings

Provider toggles, launch at login (`SMAppService`), and Quit. Preferences are stored via `UserDefaults` (`provider.<id>.enabled`, `keychainApproved`).
