# Jay plugins

A plugin teaches Jay about **one more app** — how to list that app's tabs/sessions/
windows, and how to focus one. Plugins run **out of process**: the app runs your program and reads
what it prints. That means:

- **Any language.** Your plugin can be a shell script, Python, Node, a compiled Swift/Go binary —
  anything that can print to stdout.
- **Crash-isolated.** A broken plugin can't take down the app.
- **Its own permissions.** Your plugin runs as its own process; if it scripts another app, macOS
  prompts to allow *your plugin* — the app doesn't hand over its access.

There is no linked API and nothing to compile against. The app just runs `yourprogram list` and
`yourprogram activate <id>`, exactly like you'd run a command in Terminal.

---

## Anatomy

A plugin is a **folder** containing a manifest and an executable:

```
~/Library/Application Support/Jay/Plugins/
  myplugin/
    plugin.json      # manifest (below)
    adapter          # any executable file, +x — a script or a compiled binary
```

Drop the folder in, open **Preferences ▸ Plugins ▸ Rescan** (or just re-summon), and it's picked up.
No app restart needed.

### `plugin.json`

```jsonc
{
  "apiVersion": 1,             // must be 1 (plugins with any other version are ignored)
  "name": "Terminal",          // shown in the list and used as the default section label
  "targetApp": "Terminal",     // OPTIONAL: only run this plugin while that app is running.
                               //   Match the app's display name (e.g. "Safari", "Google Chrome").
                               //   Omit to always run the plugin.
  "exec": "adapter"            // the file to run, relative to this folder. Must be executable (+x).
}
```

### The two commands

Your `exec` is invoked two ways:

**`exec list`** — print a JSON array of items to **stdout**, then exit `0`:

```json
[
  { "id": "0", "title": "Roadmap — Q3", "url": null, "active": true },
  { "id": "1", "title": "Meeting notes" }
]
```

Item fields:

| field      | required | meaning |
|------------|----------|---------|
| `id`       | ✅       | Opaque, **stable** id for this item. Passed back to `activate`. |
| `title`    | ✅       | What the user sees. |
| `subtitle` | –        | Secondary line (optional). |
| `url`      | –        | If it's a web page — drives the favicon. |
| `group`    | –        | Section label; defaults to the plugin `name`. |
| `active`   | –        | `true` for the item currently focused in the target app (helps summon land on it). |

Unknown fields are ignored. Missing `id`/`title` on an item makes the whole `list` invalid → the
plugin is skipped for that summon.

**`exec activate <id>`** — focus the item with that `id`, then exit. The `<id>` is exactly the string
you returned from `list`. (Fire-and-forget; the exit code isn't inspected.)

---

## Rules that keep the panel fast

- **Respond within ~300 ms.** On summon, every eligible plugin's `list` runs **concurrently** under
  one shared deadline. If yours is slow it's simply **dropped from that summon** (the panel never
  waits on you) — it stays visible in Preferences ▸ Plugins with a "slow / timed out" flag so the
  user can see why and disable it. It's never auto-disabled.
- **stdout is only the JSON.** Print logs/errors to **stderr**, not stdout.
- **Keep `id` stable** between `list` and `activate`. Array indices work but shift if the user
  reorders things between the two calls — prefer a real id (tab id, url, path) when the app exposes
  one.
- **Only queried when relevant.** With `targetApp` set, the app doesn't even launch your plugin
  unless that app is running.

---

## Script or binary?

Both are just an executable `exec` — the plugin structure is identical either way.

- **Script (bash/JXA/Python) — the common case.** If your app has an AppleScript/JXA dictionary
  (Safari, Notes, Mail, Finder, Music, most native apps), a plugin is ~20 lines and needs no
  toolchain. Arch-independent, runs everywhere. **Start here.** See [`terminal/`](terminal/).
- **Compiled binary (Swift/Go) — for hard targets.** When the app has no scripting and you need real
  networking/parsing (e.g. an Electron app over the Chrome DevTools Protocol), compile a binary. Two
  extra concerns then: ship a **universal** binary (arm64 + x86_64) so it runs on any Mac, and for
  public distribution **notarize** it (a downloaded, unsigned binary is Gatekeeper-blocked). An
  Electron app is reachable read-only over CDP if it's *already* launched with
  `--remote-debugging-port` — do NOT quit/relaunch the user's app to open that port.

---

## Examples in this folder

- **[`terminal/`](terminal/)** — the easy path: Apple Terminal tabs in a ~20-line shell + JXA script.
  A real, non-duplicating plugin (Terminal.app isn't covered by the built-in iTerm2 adapter).
- **[`vscode/`](vscode/)** — a companion-extension plugin: a tiny VS Code extension publishes open
  tabs to a file (no debug port), and the adapter reads them. Covers Cursor too.

## Install location

```
~/Library/Application Support/Jay/Plugins/<yourplugin>/
```

Preferences ▸ Plugins shows everything installed, each plugin's last measured latency, an enable
switch, and a **Test** button that probes `list` on demand.
