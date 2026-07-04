import Foundation

// Standalone logic tests for the plugin host (Foundation-only — no AppKit, no app build).
// Build + run (from app/):  swiftc Adapters/PluginHost.swift Tests/PluginHostTests.swift -o /tmp/phtests && /tmp/phtests

private var failures = 0, checks = 0
private func expect(_ c: Bool, _ m: String) { checks += 1; if !c { failures += 1; print("  ✗ \(m)") } }
private func eq<T: Equatable>(_ a: T, _ b: T, _ m: String) { checks += 1; if a != b { failures += 1; print("  ✗ \(m)  (got \(a), want \(b))") } }

// ── PluginItem decoding (the shape of each `list` object) ──
private func testItemDecoding() {
    print("PluginItem decoding:")
    do {
        let data = """
        [ {"id":"a","title":"One","subtitle":"src/","url":"https://x.com","group":"G","active":true},
          {"id":"b","title":"Two"} ]
        """.data(using: .utf8)!
        let items = try JSONDecoder().decode([PluginItem].self, from: data)
        eq(items.count, 2, "decodes two items")
        eq(items[0].id, "a", "id"); eq(items[0].title, "One", "title")
        eq(items[0].subtitle, "src/", "subtitle present"); eq(items[0].url, "https://x.com", "url present")
        eq(items[0].active, true, "active true")
        expect(items[1].subtitle == nil, "missing subtitle → nil")
        expect(items[1].active == nil, "missing active → nil")
    } catch { failures += 1; print("  ✗ decode threw \(error)") }
    // A bad item (missing required `title`) makes the whole list invalid.
    expect((try? JSONDecoder().decode([PluginItem].self, from: #"[{"id":"a"}]"#.data(using: .utf8)!)) == nil,
           "item missing required title → decode fails")
}

// ── PluginManifest decoding (plugin.json) ──
private func testManifestDecoding() {
    print("PluginManifest decoding:")
    do {
        let m = try JSONDecoder().decode(PluginManifest.self,
            from: #"{"apiVersion":1,"name":"VS Code","targetApp":"Code","exec":"adapter","supportsClose":true}"#.data(using: .utf8)!)
        eq(m.name, "VS Code", "name"); eq(m.targetApp, "Code", "targetApp")
        eq(m.exec, "adapter", "exec"); eq(m.supportsClose, true, "supportsClose true")
        let m2 = try JSONDecoder().decode(PluginManifest.self, from: #"{"apiVersion":1,"name":"X","exec":"a"}"#.data(using: .utf8)!)
        expect(m2.targetApp == nil, "missing targetApp → nil (always-on)")
        expect(m2.supportsClose == nil, "missing supportsClose → nil")
    } catch { failures += 1; print("  ✗ manifest decode threw \(error)") }
}

// ── Enable semantics: built-in OFF by default, drop-in/added ON by default ──
private func testEnableSemantics() {
    print("Plugin enable (source-aware defaults):")
    UserDefaults.standard.removeObject(forKey: "pluginsDisabled")
    UserDefaults.standard.removeObject(forKey: "pluginsEnabled")
    // drop-in / added → ON by default (put there deliberately)
    expect(PluginHost.isEnabled("dropin", source: .dropIn), "drop-in plugin is on by default")
    expect(PluginHost.isEnabled("added", source: .added), "added plugin is on by default")
    PluginHost.setEnabled("dropin", source: .dropIn, false)
    expect(!PluginHost.isEnabled("dropin", source: .dropIn), "drop-in off after setEnabled(false)")
    expect(PluginHost.isEnabled("other", source: .dropIn), "disabling one doesn't affect another")
    PluginHost.setEnabled("dropin", source: .dropIn, true)
    expect(PluginHost.isEnabled("dropin", source: .dropIn), "drop-in on again")
    // built-in → OFF by default (bundled; opt-in)
    expect(!PluginHost.isEnabled("term", source: .builtIn), "built-in plugin is off by default")
    PluginHost.setEnabled("term", source: .builtIn, true)
    expect(PluginHost.isEnabled("term", source: .builtIn), "built-in on after enabling")
    PluginHost.setEnabled("term", source: .builtIn, false)
    expect(!PluginHost.isEnabled("term", source: .builtIn), "built-in off again")
    UserDefaults.standard.removeObject(forKey: "pluginsDisabled")
    UserDefaults.standard.removeObject(forKey: "pluginsEnabled")
}

// ── Add / remove external plugin paths (point-in-place) ──
private func testExternalPaths() {
    print("Add / remove external plugin paths:")
    UserDefaults.standard.removeObject(forKey: "pluginPaths")
    let baseTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jay-ext-\(UUID().uuidString)")
    let good = baseTmp.appendingPathComponent("mytool")
    try? FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    try? #"{"apiVersion":1,"name":"MyTool","exec":"adapter"}"#.write(to: good.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    let adapter = good.appendingPathComponent("adapter")
    try? "#!/bin/bash\necho '[]'".write(to: adapter, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adapter.path)
    let bad = baseTmp.appendingPathComponent("empty")
    try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    expect(PluginHost.addExternalPlugin(bad) == false, "folder without a valid plugin.json is rejected")
    expect(PluginHost.addExternalPlugin(good) == true, "valid plugin folder is accepted")
    expect(PluginHost.addedPaths().contains { $0.lastPathComponent == "mytool" }, "added path is remembered")
    expect(PluginHost.loadPlugin(at: good, source: .added)?.source == .added, "loaded in place, marked .added")
    PluginHost.removeExternalPlugin(id: "mytool")
    expect(!PluginHost.addedPaths().contains { $0.lastPathComponent == "mytool" }, "removed from addedPaths")
    expect(FileManager.default.fileExists(atPath: good.path), "remove does NOT delete the user's files")
    UserDefaults.standard.removeObject(forKey: "pluginPaths")
    try? FileManager.default.removeItem(at: baseTmp)
}

// ── discover(): finds a valid plugin dir, skips invalid ones ──
private func testDiscovery() {
    print("Plugin discovery:")
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jay-phtest-\(UUID().uuidString)")
    let root = base.appendingPathComponent("Plugins")
    func makePlugin(_ name: String, _ manifest: String, executable: Bool) {
        let dir = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let adapter = dir.appendingPathComponent("adapter")
        try? "#!/bin/bash\necho '[]'".write(to: adapter, atomically: true, encoding: .utf8)
        if executable { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adapter.path) }
    }
    makePlugin("good",    #"{"apiVersion":1,"name":"Good","exec":"adapter"}"#,   executable: true)
    makePlugin("notexec", #"{"apiVersion":1,"name":"NoExec","exec":"adapter"}"#, executable: false)  // exec not +x → skipped
    makePlugin("badver",  #"{"apiVersion":99,"name":"BadVer","exec":"adapter"}"#, executable: true)  // wrong API version → skipped
    makePlugin("badjson", "{ not json",                                          executable: true)  // unparseable → skipped
    let found = PluginHost.discover(in: root)
    eq(found.count, 1, "only the valid plugin is discovered")
    expect(found.first?.manifest.name == "Good", "discovers the valid plugin by manifest")
    expect(found.first?.id == "good", "plugin id is its folder name")
    expect(found.first?.source == .dropIn, "discovered plugin carries its source")
    expect(PluginHost.discover(in: base.appendingPathComponent("nope")).isEmpty, "missing plugins dir → empty, no crash")
    try? FileManager.default.removeItem(at: base)
}

@main struct PluginHostTestRunner {
    static func main() {
        testItemDecoding()
        testManifestDecoding()
        testEnableSemantics()
        testExternalPaths()
        testDiscovery()
        print(failures == 0 ? "\n✅ all \(checks) checks passed" : "\n❌ \(failures)/\(checks) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
