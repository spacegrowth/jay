# VS Code plugin (Jay)

Lists your open VS Code editor tabs and switches to them — **no debug port, no relaunch**. It's two
pieces:

- **`extension/`** — a tiny VS Code extension ("Jay Bridge") that publishes open tabs
  via the native `window.tabGroups` API and switches to a tab on request.
- **`adapter` + `plugin.json`** — the Jay plugin that reads what the extension writes.

They talk through files in `~/Library/Application Support/Jay/`:
`vscode-<pid>.json` (one per window, tabs) and `vscode-activate.txt` (switch request). One file per
window so multiple windows don't clobber each other; the plugin merges them.

## Install

**1. The extension** — into VS Code:

```bash
cp -R extension ~/.vscode/extensions/jay-bridge
```
Then reload VS Code (⌘⇧P → "Developer: Reload Window"), or quit and reopen. (For a packaged install
instead, `npm i -g @vscode/vsce && vsce package` in `extension/`, then
`code --install-extension jay-bridge-*.vsix`.)

**2. The plugin** — into Jay:

```bash
cp -R . ~/Library/Application\ Support/Jay/Plugins/vscode   # plugin.json + adapter
```
(Excludes are fine; the plugin only needs `plugin.json` + `adapter`.)

Open Jay ▸ Preferences ▸ Plugins ▸ Rescan; "VS Code" appears once the extension has run.

## Cursor

Cursor is a VS Code fork with the same API — the **same extension** works. Install it into
`~/.cursor/extensions/` instead, and in `adapter` change `open -a "Visual Studio Code"` to
`open -a "Cursor"` (and `plugin.json`'s `targetApp` to `"Cursor"`).

## Limits (v1)

- **File tabs only** — tabs backed by a file/resource URI. Webview/terminal tabs are skipped (can't
  be re-focused by URI).
- Multi-window listing works (merged); switching routes to the owning window by pid.
