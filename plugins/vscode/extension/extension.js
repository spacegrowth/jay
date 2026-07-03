// Jay Bridge — a tiny VS Code / Cursor extension that publishes the open editor tabs
// to a file the Jay app reads, and switches to a tab on request. Uses the native
// `window.tabGroups` API: no debug port, no relaunch.
//
// IPC (in ~/Library/Application Support/Jay/):
//   vscode-<pid>.json    ← this window writes its tabs here (pid = this window's ext-host process)
//   vscode-activate.txt  → the app writes "<pid>#<uri>" here; the owning window opens+focuses it
//
// One file per window (pid-namespaced) so multiple VS Code windows don't clobber each other; the
// app-side plugin merges them. Stale files (window closed uncleanly) are pruned on activation.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');

const DIR = path.join(os.homedir(), 'Library', 'Application Support', 'Jay');
const PID = process.pid;
const MY = path.join(DIR, `vscode-${PID}.json`);
const REQ = path.join(DIR, 'vscode-activate.txt');

function tabsPayload() {
  const out = [];
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      const uri = tab.input && tab.input.uri;               // text/notebook/custom tabs carry a uri
      if (!uri) continue;                                   // skip webviews/terminals (can't refocus by uri)
      const dir = path.dirname(vscode.workspace.asRelativePath(uri, false));  // folder only (not the full path) — the filename is already the title; this disambiguates same-named files
      out.push({
        id: `${PID}#${uri.toString()}`,
        title: tab.label,
        subtitle: dir === '.' ? '' : dir,
        active: tab.isActive && group.isActive,
      });
    }
  }
  return out;
}

function writeTabs() {
  try { fs.mkdirSync(DIR, { recursive: true }); fs.writeFileSync(MY, JSON.stringify(tabsPayload())); } catch (e) {}
}

function cleanupStale() {                                    // drop files whose window process is gone
  try {
    for (const f of fs.readdirSync(DIR)) {
      const m = f.match(/^vscode-(\d+)\.json$/);
      if (!m) continue;
      try { process.kill(Number(m[1]), 0); }                // signal 0 = "is it alive?"
      catch (e) { if (e.code === 'ESRCH') { try { fs.unlinkSync(path.join(DIR, f)); } catch (_) {} } }
    }
  } catch (e) {}
}

async function activateId(id) {
  const h = id.indexOf('#');
  if (h < 0 || Number(id.slice(0, h)) !== PID) return;      // route by pid — only the owning window acts
  try {
    const uri = vscode.Uri.parse(id.slice(h + 1));
    const doc = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(doc, { preview: false });
  } catch (e) {}
}

async function closeId(id) {
  const h = id.indexOf('#');
  if (h < 0 || Number(id.slice(0, h)) !== PID) return;      // route by pid — only the owning window closes
  const uriStr = id.slice(h + 1);
  try {
    for (const group of vscode.window.tabGroups.all) {
      for (const tab of group.tabs) {
        const u = tab.input && tab.input.uri;
        if (u && u.toString() === uriStr) { await vscode.window.tabGroups.close(tab); return; }
      }
    }
  } catch (e) {}
}

function activate(context) {
  cleanupStale();
  writeTabs();
  const rewrite = () => writeTabs();
  context.subscriptions.push(
    vscode.window.tabGroups.onDidChangeTabs(rewrite),
    vscode.window.tabGroups.onDidChangeTabGroups(rewrite),
    vscode.window.onDidChangeActiveTextEditor(rewrite),
    vscode.window.onDidChangeWindowState(rewrite),
  );
  try { fs.mkdirSync(DIR, { recursive: true }); } catch (e) {}
  try {
    const watcher = fs.watch(DIR, (_, filename) => {
      if (filename === 'vscode-activate.txt') {
        fs.readFile(REQ, 'utf8', (err, data) => { if (!err && data && data.trim()) activateId(data.trim()); });
      } else if (filename === 'vscode-close.txt') {
        fs.readFile(path.join(DIR, 'vscode-close.txt'), 'utf8', (err, data) => { if (!err && data && data.trim()) closeId(data.trim()); });
      }
    });
    context.subscriptions.push({ dispose: () => watcher.close() });
  } catch (e) {}
}

function deactivate() { try { fs.unlinkSync(MY); } catch (e) {} }

module.exports = { activate, deactivate };
