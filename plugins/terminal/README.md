# Terminal plugin

Lists **Apple Terminal.app** tabs in Jay and switches to one on demand. (Jay's built-in adapter
covers iTerm2; this plugin adds plain Terminal.app.)

It's also the **simplest example of the plugin contract** — one ~50-line shell script, no build
step, no dependencies. Copy it as a starting point for your own plugin.

## What it does

- **`./adapter list`** → prints a JSON array of the open Terminal tabs (via JavaScript-for-Automation):
  ```json
  [ { "id": "/dev/ttys012", "title": "vim main.rs", "subtitle": "/dev/ttys012", "active": true } ]
  ```
  The `id` is the tab's **tty** (e.g. `/dev/ttys012`) — stable across tab reordering, so `activate`
  always resolves to the right tab. `title` is the tab's custom title, or the running process if none.

- **`./adapter activate <id>`** → selects the tab whose tty matches `<id>` and brings Terminal forward.

## Files

| File | |
|------|--|
| `plugin.json` | Manifest: `name`, `targetApp: "Terminal"` (only queried while Terminal runs), `exec: "adapter"`. |
| `adapter`     | Executable shell script implementing `list` / `activate`. Must stay `chmod +x`. |

## Install

1. Copy this `terminal/` folder into Jay's plugins folder — **Preferences → Plugins → Reveal in Finder**
   (`~/Library/Application Support/Jay/Plugins/`).
2. **Preferences → Plugins → Rescan.** Installed plugins are on by default; toggle it off there if you like.

## Requirements

- **Automation** permission for Terminal (macOS prompts the first time Jay queries it).
- No AppleScript debug port or relaunch — it reads Terminal's live tab list each time.

See [`../README.md`](../README.md) for the full plugin contract, and the site's
[**Generate one with AI**](https://spacegrowth.github.io/jay/#plugins) prompt to scaffold a new plugin.
