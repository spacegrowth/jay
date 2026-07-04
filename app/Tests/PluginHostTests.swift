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

// ── Enable semantics: ON by default, tracked as a DISABLED set ──
private func testEnableSemantics() {
    print("Plugin enable (on by default):")
    UserDefaults.standard.removeObject(forKey: "pluginsDisabled")
    expect(PluginHost.isEnabled("fresh"), "a never-touched plugin is enabled by default")
    PluginHost.setEnabled("fresh", false)
    expect(!PluginHost.isEnabled("fresh"), "disabled after setEnabled(false)")
    expect(PluginHost.isEnabled("other"), "disabling one doesn't disable another")
    PluginHost.setEnabled("fresh", true)
    expect(PluginHost.isEnabled("fresh"), "re-enabled after setEnabled(true)")
    UserDefaults.standard.removeObject(forKey: "pluginsDisabled")
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
    expect(PluginHost.discover(in: base.appendingPathComponent("nope")).isEmpty, "missing plugins dir → empty, no crash")
    try? FileManager.default.removeItem(at: base)
}

@main struct PluginHostTestRunner {
    static func main() {
        testItemDecoding()
        testManifestDecoding()
        testEnableSemantics()
        testDiscovery()
        print(failures == 0 ? "\n✅ all \(checks) checks passed" : "\n❌ \(failures)/\(checks) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
