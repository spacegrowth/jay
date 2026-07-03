import Foundation

// Out-of-process plugin host. A plugin is a directory under the plugins root containing a
// `plugin.json` manifest + an executable. The host runs `<exec> list` to enumerate items and
// `<exec> activate <id>` to focus one. Language-agnostic (the exec can be a script or a binary);
// crash-isolated (a bad plugin can't take down the app); and each plugin runs with its OWN
// permissions, not the app's. This file is AppKit-free so the core is unit-testable; the TabRef
// bridge lives in Adapters.swift.

let kPluginAPIVersion = 1

/// One item a plugin reports — the shape of each object in `list`'s JSON output.
struct PluginItem: Decodable {
    let id: String            // stable within a plugin; passed back to `activate <id>`
    let title: String
    let subtitle: String?
    let url: String?          // drives favicon for web items
    let group: String?        // section label; defaults to the plugin name
    let active: Bool?         // the item currently focused in the target app (for summon landing)
}

/// A plugin's manifest (plugin.json).
struct PluginManifest: Decodable {
    let apiVersion: Int
    let name: String
    let targetApp: String?    // app name to gate on — only queried while that app runs; nil = always
    let exec: String          // executable/script path, relative to the plugin directory
    let supportsClose: Bool?  // plugin handles `exec close <id>` → items get a hover-× (e.g. VS Code)
}

struct LoadedPlugin {
    let manifest: PluginManifest
    let dir: URL
    var id: String { dir.lastPathComponent }     // stable identity = folder name (unique on disk)
    var execURL: URL { dir.appendingPathComponent(manifest.exec) }
}

/// Snapshot for the Preferences ▸ Plugins tab: what's installed and how it's doing.
struct PluginStatus {
    let id: String
    let name: String
    let targetApp: String?
    let enabled: Bool
    let lastMs: Double?          // last measured `list` latency; nil = never run, <0 = timed out/failed
}

enum PluginHost {
    /// Default plugins root: ~/Library/Application Support/Jay/Plugins
    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Jay/Plugins", isDirectory: true)

    /// Discover valid plugins: each is a subdirectory with a parseable `plugin.json` (matching this
    /// API version) whose `exec` is an executable file. Invalid/foreign-version plugins are skipped.
    static func discover(in root: URL = PluginHost.root) -> [LoadedPlugin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []   // no plugins dir yet → no plugins (normal)
        }
        var out: [LoadedPlugin] = []
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let manifestURL = dir.appendingPathComponent("plugin.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let m = try? JSONDecoder().decode(PluginManifest.self, from: data),
                  m.apiVersion == kPluginAPIVersion else { continue }
            let p = LoadedPlugin(manifest: m, dir: dir)
            if fm.isExecutableFile(atPath: p.execURL.path) { out.append(p) }
        }
        return out
    }

    /// Run a plugin subcommand, capture stdout, enforce a timeout. Returns nil on launch failure,
    /// timeout, or non-zero exit. Kills the process if it overruns so a hung plugin can't stall us.
    /// SHORTCUT: reads stdout after exit — fine for small `list` payloads; stream if a plugin ever
    /// emits >~64KB (pipe buffer) before exiting.
    static func run(_ plugin: LoadedPlugin, _ args: [String], timeout: TimeInterval) -> Data? {
        let proc = Process()
        proc.executableURL = plugin.execURL
        proc.arguments = args
        proc.currentDirectoryURL = plugin.dir
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()          // swallow stderr (surfaced in a debug view later)
        do { try proc.run() } catch { return nil }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        return out.fileHandleForReading.readDataToEndOfFile()
    }

    /// Query every eligible plugin's `list` CONCURRENTLY under one shared deadline, so a slow plugin
    /// only drops itself (total wall-clock ≈ one deadline, not the sum). Skips disabled plugins and
    /// those whose `targetApp` isn't running. Records each plugin's measured latency for the
    /// Preferences ▸ Plugins tab. `flag-only`: slow plugins are recorded/flagged, never auto-disabled.
    static func listAll(in root: URL = PluginHost.root,
                        deadline: TimeInterval = 0.3,
                        isRunning: (String) -> Bool) -> [(plugin: LoadedPlugin, items: [PluginItem])] {
        let eligible = discover(in: root).filter { p in
            if !isEnabled(p.id) { return false }                       // opt-in: skip until user enables
            if let target = p.manifest.targetApp, !isRunning(target) { return false }
            return true
        }
        guard !eligible.isEmpty else { return [] }

        var results = [[PluginItem]?](repeating: nil, count: eligible.count)
        var elapsed = [Double](repeating: -1, count: eligible.count)   // ms; -1 = timed out / failed
        let group = DispatchGroup()
        let sema = DispatchSemaphore(value: 16)                        // concurrency cap (fork-bomb guard)
        let lock = NSLock()

        for (i, p) in eligible.enumerated() {
            group.enter(); sema.wait()
            DispatchQueue.global().async {
                let start = Date()
                let data = run(p, ["list"], timeout: deadline)
                let ms = Date().timeIntervalSince(start) * 1000
                if let data, let items = try? JSONDecoder().decode([PluginItem].self, from: data) {
                    lock.lock(); results[i] = items; elapsed[i] = ms; lock.unlock()
                }
                sema.signal(); group.leave()
            }
        }
        _ = group.wait(timeout: .now() + deadline + 0.1)              // shared backstop (runs self-time-out too)

        lock.lock(); defer { lock.unlock() }
        for (i, p) in eligible.enumerated() { recordLatency(p.id, ms: elapsed[i]) }
        return eligible.enumerated().compactMap { i, p in results[i].map { (p, $0) } }
    }

    // MARK: state (enable/disable + latency) — persisted so the Preferences tab reflects it

    // ON by default: an installed plugin works out of the box. We track the DISABLED set instead,
    // so a plugin runs unless the user explicitly turns it off in Preferences ▸ Plugins. (Plugins
    // only ever live in a folder the user controls, so presence already implies intent.)
    private static let kDisabled = "pluginsDisabled"
    private static let kLatency = "pluginLatency"

    static func isEnabled(_ id: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: kDisabled) ?? []).contains(id)
    }
    static func setEnabled(_ id: String, _ enabled: Bool) {
        var s = Set(UserDefaults.standard.stringArray(forKey: kDisabled) ?? [])
        if enabled { s.remove(id) } else { s.insert(id) }
        UserDefaults.standard.set(Array(s), forKey: kDisabled)
    }
    static func lastLatencyMs(_ id: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: kLatency) as? [String: Double])?[id]
    }
    private static func recordLatency(_ id: String, ms: Double) {
        var d = (UserDefaults.standard.dictionary(forKey: kLatency) as? [String: Double]) ?? [:]
        d[id] = ms
        UserDefaults.standard.set(d, forKey: kLatency)
    }

    /// On-demand probe (the Preferences "Test" button): run one `list` with a generous timeout,
    /// record the latency, and report how long it took + how many items it returned (-1 = failed).
    @discardableResult
    static func probe(id: String, in root: URL = PluginHost.root) -> (ms: Double, items: Int)? {
        guard let p = discover(in: root).first(where: { $0.id == id }) else { return nil }
        let start = Date()
        let data = run(p, ["list"], timeout: 2.0)
        let ms = data == nil ? -1 : Date().timeIntervalSince(start) * 1000
        let count = data.flatMap { try? JSONDecoder().decode([PluginItem].self, from: $0) }?.count ?? -1
        recordLatency(id, ms: ms)
        return (ms, count)
    }

    /// Everything installed + its state — for the Preferences ▸ Plugins list.
    static func statuses(in root: URL = PluginHost.root) -> [PluginStatus] {
        discover(in: root).map { p in
            PluginStatus(id: p.id, name: p.manifest.name, targetApp: p.manifest.targetApp,
                         enabled: isEnabled(p.id), lastMs: lastLatencyMs(p.id))
        }
    }
}
