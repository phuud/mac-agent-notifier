# mac-agent-notifier

Clickable macOS notifications for CLI-based AI coding agents (Claude Code, Codex CLI, etc.) — **clicking the notification activates the terminal app you launched the agent from**, not Script Editor.

Display name: **Agent Notifier**. Bundle ID: `com.phuud.mac-agent-notifier`.

## Why this exists

The obvious ways to post a macOS notification from a shell hook all have fatal flaws on modern macOS (tested on Sonoma 14.4):

| Approach | Problem |
|---|---|
| `osascript -e 'display notification ...'` | Top label is always "Script Editor", click always opens Script Editor. Apple hard-codes the attribution. |
| `osacompile`-produced `.app` calling `display notification` | Same — Apple routes every AppleScript notification through Script Editor regardless of the hosting bundle. |
| `terminal-notifier` (Homebrew) | `-sender` silently drops the notification if the target app lacks its own notification permission. `-activate` and `-execute` click handlers are broken on macOS 11+ (uses deprecated `NSUserNotification` API). |

The only reliable fix is a real LSUIElement `.app` bundle that uses the modern `UNUserNotificationCenter` framework end-to-end — which is what this is.

## What it does

- Posts a macOS notification via `UNUserNotificationCenter` (title / subtitle / body / sound)
- Stores the target terminal app's bundle ID in the notification's `userInfo`
- **Default click**: macOS relaunches this app, the delegate reads `userInfo["targetBundleID"]` and calls `NSWorkspace.openApplication(...)` to bring that terminal to the foreground
- **Optional "Allow" button** (when the hook passes a Claude PID): walks the PPID chain to find the specific terminal window hosting that Claude session, raises it via the Accessibility API, posts `1` + Return into the TUI permission menu, then restores the previously-focused app
- Since the app is `LSUIElement=true`, it never shows up in the Dock or menu bar — each launch handles its event and exits

## Requirements

- macOS 11+ (Big Sur or later)
- Xcode Command Line Tools (ships `swiftc`, `codesign`)
- Apple Silicon Mac — `build.sh` targets `arm64-apple-macos11`; change `-target` to build for Intel

## Install

### Via Homebrew (recommended)

```bash
brew tap phuud/mac-agent-notifier https://github.com/phuud/mac-agent-notifier
brew install --cask mac-agent-notifier
```

Installs to `/Applications/Agent Notifier.app`. Homebrew strips the `com.apple.quarantine` attribute on install so the bundle launches without Gatekeeper's "unverified developer" warning.

Upgrade later via `brew upgrade --cask mac-agent-notifier`. Because the app uses ad-hoc signing (different code-signing hash on every CI build), expect to re-grant Accessibility permission after each upgrade — see the **Rebuild caveat** below.

### Via source

```bash
git clone https://github.com/phuud/mac-agent-notifier.git
cd mac-agent-notifier
./build.sh
```

Installs to `~/Applications/Agent Notifier.app` by default. Override with an env var:

```bash
AGENT_NOTIFIER_INSTALL_DIR=/some/other/dir ./build.sh
```

> **Path differences**: the Homebrew cask installs to `/Applications`, source build defaults to `~/Applications`. Integration snippets below use `~/Applications` — if you installed via brew, substitute `/Applications` in the paths.

### First-run permissions (once per machine)

1. First notification posted → macOS asks to allow notifications from "Agent Notifier". Click Allow.
2. First "Allow" button click → macOS asks for **Accessibility** permission (needed to focus the target window and inject the `1` keystroke). Open System Settings → Privacy & Security → Accessibility and toggle `Agent Notifier` on.

### Caveat about rebuilds

`build.sh` uses ad-hoc signing (`codesign --sign -`). Every rebuild produces a new code-signing hash, which **invalidates the Accessibility grant** even though the toggle in System Settings may still appear on. Symptom: button click silently fails.

Fix:

```bash
tccutil reset Accessibility com.phuud.mac-agent-notifier
```

Then click "Allow" on a test notification to re-trigger the permission flow, and enable the new entry under System Settings → Privacy & Security → Accessibility. Toggling the existing switch off/on is usually not enough — the record is still bound to the previous code-signing hash.

## Usage

```
open -n -a "$HOME/Applications/Agent Notifier.app" --args <title> <subtitle> <body> <sound> <bundleID> [claudePID]
```

| Arg | Purpose | Example |
|---|---|---|
| `title` | First line (bold) of the notification body | `Claude Code · Ghostty` |
| `subtitle` | Second line | `20:07:39` |
| `body` | Message text | `Run: git status` |
| `sound` | macOS system sound name (omit `.aiff`) | `Glass`, `Pop`, `Submarine` |
| `bundleID` | App to activate on click | `com.mitchellh.ghostty` |
| `claudePID` | Optional: the Claude process PID. When non-empty & > 0, the notification gets an **"Allow"** action button that posts `1` + Return into that Claude session's terminal window. Omit or pass `""` for a plain notification with no action buttons. | `94824` |

Any arg can be an empty string to use the default. Pass nothing and the app exits without posting (this also happens when macOS relaunches the app to deliver a click response).

> **Quote the path.** The installed bundle's filename has a space — always wrap it in double quotes in shell commands.

## Integration

### Claude Code hooks

The `.app` ships with `notify.sh` inside its Resources directory — no separate hook script to install. Wire it into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/Applications/Agent\\ Notifier.app/Contents/Resources/notify.sh" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "~/Applications/Agent\\ Notifier.app/Contents/Resources/notify.sh \"Task done\" \"Pop\" \"Claude Code\" \"0\"" }] }]
  }
}
```

The `\\` escapes the space in the path (JSON → shell double-backslash → shell single-backslash-space → literal space).

Why only `PermissionRequest` and `Stop` (not `Notification`):

- `PermissionRequest` fires when Claude first decides to ask the user about a tool call.
- `Notification` fires again 60 seconds later if the user hasn't responded — a reminder. Subscribing to both produces duplicate notifications for the same request. `PermissionRequest` alone is enough.
- `Stop` fires when a turn finishes. The `"0"` 4th arg disables the action button for this event (task completion doesn't need an "Allow" button).

What `notify.sh` does:

- Parses Claude's hook stdin JSON (`.message` / `.tool_name` + `.tool_input`)
- Walks the PPID chain to identify the terminal (Cursor / iTerm / Ghostty / Terminal / VS Code)
- Builds title `Claude Code · <terminal>` with the current time as subtitle
- Launches the enclosing `.app` to post the notification; attaches the "Allow" button when stdin looks like a permission request (auto-detect) or when the 4th arg forces it

Script args (all positional):
1. `default_message` — used when stdin has no `.message` / `.tool_name`
2. `sound_name` — `Glass`, `Pop`, etc. (default `Glass`)
3. `title_prefix` — e.g. `"Claude Code"`, `"Codex"` (default `"Claude Code"`)
4. `actionable` — `1` force button on, `0` force off, empty = auto (based on stdin)

### Codex CLI (via shell wrapper)

Codex CLI has a plugin-based hook system that's heavier to set up. A shell-level wrapper is the pragmatic alternative — it fires whenever `codex` exits (covers `codex exec ...` completely; fires once when TUI is exited):

```bash
# In ~/.zshrc or ~/.bashrc
codex() {
  command codex "$@"
  local exit_code=$?
  case "${1:-}" in
    --version|-V|--help|-h|help|completion|features|login|logout|debug|mcp|mcp-server)
      return $exit_code
      ;;
  esac
  "$HOME/Applications/Agent Notifier.app/Contents/Resources/notify.sh" "Codex task done" "Pop" "Codex" "0" < /dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
  return $exit_code
}
```

### Generic use

For any other CLI, call the notifier directly:

```bash
open -n -a "$HOME/Applications/Agent Notifier.app" --args "Build done" "$(date +%H:%M)" "make succeeded" "Glass" "com.mitchellh.ghostty"
```

## Project layout

```
mac-agent-notifier/
├── main.swift            # the app — UNUserNotificationCenter + Accessibility keystroke injection
├── notify.sh             # shell hook glue — bundled into Contents/Resources/
├── Info.plist            # bundle metadata (LSUIElement=true, bundle id, display name)
├── build.sh              # swiftc + codesign + lsregister → installs into ~/Applications/
├── AppIcon.icns          # rounded gradient square with a robot head + red dot
├── scripts/
│   └── build-dmg.sh      # package the .app into a distributable DMG
├── Casks/
│   └── mac-agent-notifier.rb  # Homebrew cask (this repo doubles as a tap)
├── .github/workflows/
│   └── release.yml       # on `git push --tags`: build DMG, bump cask, create GH release
└── README.md
```

Notes:

- **`LSUIElement=true`** keeps the app out of the Dock and menu bar. Click relaunches it, it runs the delegate callback, and exits immediately — invisible UI.
- **Ad-hoc codesign** (`codesign --force --sign -`) produces a new code-signing hash on every build. Accessibility grants (TCC) are pinned to that hash and invalidate on rebuild — see the caveat above.
- **`lsregister -f`** is required whenever `Info.plist` changes, otherwise LaunchServices caches the old bundle identity.

## Troubleshooting

**No notification appears after `./build.sh`**
Check System Settings → Notifications. If there's no "Agent Notifier" entry, post a test notification and accept the permission prompt:
```bash
open -n -a "$HOME/Applications/Agent Notifier.app" --args "test" "" "hello" "Glass" ""
```

**Notification appears but click does nothing**
Ensure the 5th arg is a real bundle ID (`mdfind "kMDItemCFBundleIdentifier == 'com.mitchellh.ghostty'"`). If the bundle ID doesn't resolve, the click handler exits silently.

**"Allow" button click focuses the right window but no `1` gets typed**
Accessibility permission is stale (invalidated by a rebuild). Toggling the switch off and on is usually not enough — the TCC record is still bound to the old code-signing hash. Reset cleanly:

```bash
tccutil reset Accessibility com.phuud.mac-agent-notifier
```

Then click "Allow" again to re-trigger the prompt, and enable the new entry in System Settings → Privacy & Security → Accessibility.

**Notification top label says "Script Editor" instead of "Agent Notifier"**
Another process is sending the notification, not this app. Double-check the hook script actually invokes `Agent Notifier.app` (grep for `osascript` — it shouldn't be there).

**`brew install --cask mac-agent-notifier` picks a different cask than this one**
Use the fully-qualified form to disambiguate:
```bash
brew install --cask phuud/mac-agent-notifier/mac-agent-notifier
```
The three segments are `<user>/<tap>/<cask>`.

## Releasing a new version

This repo is its own Homebrew tap. Tags drive releases:

```bash
git tag v0.1.1
git push origin v0.1.1
```

GitHub Actions (`.github/workflows/release.yml`) then:

1. Builds the `.app` on a `macos-14` runner
2. Packages it into `dist/Agent-Notifier-<version>.dmg` via `scripts/build-dmg.sh`
3. Reads the DMG's sha256 and rewrites the `version` + `sha256` lines in `Casks/mac-agent-notifier.rb`
4. Commits the cask bump back to `main`
5. Creates a GitHub release with the DMG attached

Users upgrade via `brew upgrade --cask mac-agent-notifier`.

To build a DMG locally for testing:

```bash
./scripts/build-dmg.sh 0.1.0
# → dist/Agent-Notifier-0.1.0.dmg + dist/SHA256
```

## Uninstall

```bash
# Homebrew install:
brew uninstall --cask mac-agent-notifier

# Source install:
rm -rf "$HOME/Applications/Agent Notifier.app"

# Clear macOS permissions
tccutil reset Accessibility com.phuud.mac-agent-notifier
# System Settings → Notifications → Agent Notifier → remove
```

## License

MIT — do whatever. Attribution appreciated but not required.
