# Claude-O-Meter for macOS

Two tiny native apps showing your current Claude **session** and **weekly**
usage (and when each resets), so you can see how close you are to a limit
before you hit it. Native ports of the Claude-O-Meter userscript for claude.ai.

| App | What it looks like |
|---|---|
| **`ClaudeOMeter.app`** (menu bar) | A colored progress ring + session percentage in the menu bar. Click for the usage panel. |
| **`ClaudeOMeterFloat.app`** (floating) | A draggable circular button — the Claude glyph inside a colored usage ring — floating above all windows on every Space, just like the userscript's overlay. Click toggles the panel, drag moves it (position persists), right-click for a menu (refresh / open claude.ai / quit). |

Ring colors: green &lt; 60%, amber &lt; 85%, red above. The panel shows:

- **Current session** — percent used and a countdown ("resets in 3h 12m")
- **Weekly (all models)** — percent used and the absolute reset date
- **Weekly · &lt;model&gt;** — any per-model weekly limits the API reports (e.g. Fable/Opus)
- **Claude in terminals** — every running `claude` CLI session: its working
  directory and how long it's been up (hover a row for the full path + pid).
  Click a row for actions: **Terminate** (SIGTERM — clean exit, session stays
  resumable via `claude --resume`), **Force kill** (SIGKILL, for ghost
  sessions that ignore SIGTERM), or **Copy PID**.
- Refresh button, link to claude.ai's usage page, and Quit

Usage refreshes every 120 seconds, plus once immediately on wake from sleep.
On HTTP 429 the app backs off for at least 5 minutes (the endpoint has a
rate limit); the manual refresh button always overrides the backoff.
Run either app or both — they're independent.

Terminal sessions are found with `pgrep -x claude` (exact, case-sensitive —
the Claude **desktop** app's processes are named `Claude` and don't match)
and their working directories with `lsof`. Purely local; no network involved.

## How they get the data

They read the **Claude Code OAuth token** from your macOS Keychain (the
`Claude Code-credentials` item that the `claude` CLI maintains) and call
`GET https://api.anthropic.com/api/oauth/usage` — the same endpoint Claude
Code's `/usage` screen uses. Nothing is sent anywhere except that one
Anthropic endpoint; the token never leaves your machine.

Credential lookup order:

1. `CLAUDE_CODE_OAUTH_TOKEN` env var (debugging override)
2. Keychain item `Claude Code-credentials`
3. `~/.claude/.credentials.json` (fallback for file-based installs)

> ⚠️ The endpoint is unofficial/undocumented and could change. The parser is
> deliberately tolerant (mirrors the userscript): it prefers the `limits`
> array and falls back to the `five_hour` / `seven_day` summary objects.

## Requirements

- macOS 13+
- Swift toolchain (Xcode or Command Line Tools)
- A Claude Code login on this machine (`claude` CLI signed in)

## Build & run

```sh
./build.sh
open ClaudeOMeter.app        # menu bar
open ClaudeOMeterFloat.app   # floating button
```

**First launch (each app):** macOS asks whether the app may read the
`Claude Code-credentials` Keychain item. Click **Always Allow** so it doesn't
ask again. The two apps are separate binaries, so each prompts once. (The
build script ad-hoc-signs the apps so that choice sticks — but each *rebuild*
produces a new signature, so you'll be re-asked once per rebuild.)

**Start at login:** tick "Launch at login" in the app's panel, or from the CLI:

```sh
./ClaudeOMeterFloat.app/Contents/MacOS/ClaudeOMeterFloat --login-item on   # or off / status
```

Each app registers itself independently (via `SMAppService`), and the entry
shows up in System Settings → General → Login Items where it can also be
removed. Registration is tied to the app's path — if you move the `.app`,
re-enable it.

## CLI modes

One-shot fetch, print, exit — useful for debugging or scripting (both binaries):

```sh
./ClaudeOMeter.app/Contents/MacOS/ClaudeOMeter --check
# Current session: 27% (resets 2026-07-13T19:59:59Z)
# Weekly (all models): 5% (resets 2026-07-14T14:59:59Z)
# Weekly · Fable: 9% (resets 2026-07-14T14:59:59Z)
```

Render the floating button to PNGs without launching the UI (float binary only):

```sh
./ClaudeOMeterFloat.app/Contents/MacOS/ClaudeOMeterFloat --render-icon /tmp/button
# writes /tmp/button-light.png and /tmp/button-dark.png
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No Claude Code credentials found" | Sign in once with the `claude` CLI. |
| "Token expired or rejected" | Use Claude Code once (it refreshes the token), then hit refresh. The apps never write to the Keychain, so they can't refresh the token themselves. |
| `!` in the menu bar / gray ring on the float button | Open the panel — the error message says what's wrong. |
| Keychain prompt on every launch | You clicked "Allow" instead of "Always Allow", or the app was rebuilt (new signature). |
| Float button lost off-screen | Its saved position is discarded automatically if it's not on any connected screen; quit + relaunch resets it to the bottom-right corner. |

## Layout

```
Sources/Core.swift        — shared: credentials, usage client, model, panel UI, Claude glyph
Sources/MenuBarApp.swift  — @main for ClaudeOMeter.app (MenuBarExtra)
Sources/FloatApp.swift    — @main for ClaudeOMeterFloat.app (floating NSPanel + drag/click)
Info.plist                — bundle metadata, menu bar app
Info-Float.plist          — bundle metadata, floating app
build.sh                  — swiftc → two .app bundles → ad-hoc codesign
```
