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

/// Where a plugin came from: bundled in the app, dropped into the support dir, or a folder the
/// user pointed Jay at. Drives the default enabled state and the Preferences label.
enum PluginSource { case builtIn, dropIn, added }

struct LoadedPlugin {
    let manifest: PluginManifest
    let dir: URL
    let source: PluginSource
    var id: String { dir.lastPathComponent }     // stable identity = folder name (unique on disk)
    var execURL: URL { dir.appendingPathComponent(manifest.exec) }
}

/// Snapshot for the Preferences ▸ Plugins tab: what's installed and how it's doing.
struct PluginStatus {
    let id: String
    let name: String
    let targetApp: String?
    let enabled: Bool
    let source: PluginSource
    let lastMs: Double?          // last measured `list` latency; nil = never run, <0 = timed out/failed
}

enum PluginHost {
    /// Default plugins root: ~/Library/Application Support/Jay/Plugins
    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Jay/Plugins", isDirectory: true)

    /// Built-in plugins ship inside the app bundle (Contents/Resources/Plugins).
    static var builtInRoot: URL? { Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true) }

    /// Load one plugin folder if it's valid: a parseable `plugin.json` (matching this API version)
    /// whose `exec` is an executable file. Returns nil for anything invalid or a foreign version.
    static func loadPlugin(at dir: URL, source: PluginSource) -> LoadedPlugin? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
              let m = try? JSONDecoder().decode(PluginManifest.self, from: data),
              m.apiVersion == kPluginAPIVersion else { return nil }
        let p = LoadedPlugin(manifest: m, dir: dir, source: source)
        return FileManager.default.isExecutableFile(atPath: p.execURL.path) ? p : nil
    }

    /// Discover valid plugins inside a parent directory (each plugin is a subfolder).
    static func discover(in root: URL = PluginHost.root, source: PluginSource = .dropIn) -> [LoadedPlugin] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []   // no such dir → no plugins (normal)
        }
        return entries.compactMap { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return loadPlugin(at: dir, source: source)
        }
    }

    /// Every plugin across the three sources — app bundle (built-in), the support-dir Plugins folder
    /// (drop-in), and the user's added folders — deduped by id (added/drop-in override a built-in).
    static func discoverAll() -> [LoadedPlugin] {
        var out: [LoadedPlugin] = []; var seen = Set<String>()
        func add(_ ps: [LoadedPlugin]) { for p in ps where seen.insert(p.id).inserted { out.append(p) } }
        add(addedPaths().compactMap { loadPlugin(at: $0, source: .added) })   // user-pointed folders win
        add(discover(in: root, source: .dropIn))
        if let b = builtInRoot { add(discover(in: b, source: .builtIn)) }
        return out
    }

    // ── user-added plugin folders: pointed at wherever they live, loaded in place ──
    private static let kExtraPaths = "pluginPaths"
    static func addedPaths() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: kExtraPaths) ?? []).map { URL(fileURLWithPath: $0) }
    }
    /// Point Jay at a plugin folder wherever it lives. Returns false if it isn't a valid plugin.
    @discardableResult
    static func addExternalPlugin(_ url: URL) -> Bool {
        guard loadPlugin(at: url, source: .added) != nil else { return false }
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: kExtraPaths) ?? []
        if !paths.contains(path) { paths.append(path); UserDefaults.standard.set(paths, forKey: kExtraPaths) }
        return true
    }
    /// Forget an added plugin (never touches the user's files).
    static func removeExternalPlugin(id: String) {
        let paths = (UserDefaults.standard.stringArray(forKey: kExtraPaths) ?? [])
            .filter { URL(fileURLWithPath: $0).lastPathComponent != id }
        UserDefaults.standard.set(paths, forKey: kExtraPaths)
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
    static func listAll(deadline: TimeInterval = 0.3,
                        isRunning: (String) -> Bool) -> [(plugin: LoadedPlugin, items: [PluginItem])] {
        let eligible = discoverAll().filter { p in
            if !isEnabled(p) { return false }                          // built-in: opt-in; drop-in/added: on by default
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

    // Enable defaults depend on the source. Built-in plugins are bundled with the app, so presence
    // isn't intent — they're OFF until the user turns them on (first-run checklist or Preferences),
    // tracked as an ENABLED set. Drop-in and user-added plugins are put there deliberately, so
    // they're ON by default, tracked as a DISABLED set.
    private static let kEnabled  = "pluginsEnabled"    // built-in ids the user turned ON
    private static let kDisabled = "pluginsDisabled"   // drop-in/added ids the user turned OFF
    private static let kLatency  = "pluginLatency"

    static func isEnabled(_ id: String, source: PluginSource) -> Bool {
        if source == .builtIn { return (UserDefaults.standard.stringArray(forKey: kEnabled) ?? []).contains(id) }
        return !(UserDefaults.standard.stringArray(forKey: kDisabled) ?? []).contains(id)
    }
    static func isEnabled(_ p: LoadedPlugin) -> Bool { isEnabled(p.id, source: p.source) }

    static func setEnabled(_ id: String, source: PluginSource, _ on: Bool) {
        let key  = source == .builtIn ? kEnabled : kDisabled
        let want = source == .builtIn ? on : !on          // built-in set holds ENABLED ids; other set holds DISABLED ids
        var s = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if want { s.insert(id) } else { s.remove(id) }
        UserDefaults.standard.set(Array(s), forKey: key)
    }
    /// Convenience for callers that only have an id (e.g. a Preferences toggle) — resolves the source.
    static func setEnabled(_ id: String, _ on: Bool) {
        setEnabled(id, source: discoverAll().first { $0.id == id }?.source ?? .dropIn, on)
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
    static func probe(id: String) -> (ms: Double, items: Int)? {
        guard let p = discoverAll().first(where: { $0.id == id }) else { return nil }
        let start = Date()
        let data = run(p, ["list"], timeout: 2.0)
        let ms = data == nil ? -1 : Date().timeIntervalSince(start) * 1000
        let count = data.flatMap { try? JSONDecoder().decode([PluginItem].self, from: $0) }?.count ?? -1
        recordLatency(id, ms: ms)
        return (ms, count)
    }

    /// Everything installed + its state — for the Preferences ▸ Plugins list.
    static func statuses() -> [PluginStatus] {
        discoverAll().map { p in
            PluginStatus(id: p.id, name: p.manifest.name, targetApp: p.manifest.targetApp,
                         enabled: isEnabled(p), source: p.source, lastMs: lastLatencyMs(p.id))
        }
    }
}
