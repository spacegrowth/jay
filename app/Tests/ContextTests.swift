import Foundation

// Standalone test runner for the Contexts logic (Foundation-only — no AppKit, no app build).
// Build + run (from app/):  swiftc Contexts/ContextKey.swift Contexts/ContextEngine.swift Contexts/ContextOverrides.swift Contexts/ContextLabeler.swift Contexts/ContextStore.swift Tests/ContextTests.swift -o /tmp/ctxtests && /tmp/ctxtests
// NOT part of build.sh (app target) — pure logic verification.

private struct Stub: ContextItem { let app: String; let title: String; let url: String?; let cwd: String? }
private func item(_ app: String, _ title: String, _ url: String? = nil, cwd: String? = nil) -> Stub {
    Stub(app: app, title: title, url: url, cwd: cwd)
}

private var failures = 0, checks = 0
private func expect(_ cond: Bool, _ msg: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ \(msg)") }
}
private func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    checks += 1
    if a != b { failures += 1; print("  ✗ \(msg)  (got \(a), want \(b))") }
}

// MARK: ContextKey

private func testKeys() {
    print("ContextKey:")
    eq(ContextKey.keyFromURL("https://github.com/acme/api/pull/3"), "proj:api", "github repo → proj")
    eq(ContextKey.keyFromURL("https://gitlab.com/org/web"), "proj:web", "gitlab repo → proj")
    eq(ContextKey.keyFromURL("http://localhost:3000/x"), "local:3000", "localhost → port")
    eq(ContextKey.keyFromURL("https://mail.google.com/u/0"), "site:google.com", "subdomain → registrable")
    eq(ContextKey.keyFromURL("https://news.ycombinator.com"), "site:ycombinator.com", "plain host")
    // cwd is the primary terminal signal (real working directory)
    eq(ContextKey.key(item("iTerm2", "zsh", cwd: "/Users/dev/work/api")), "proj:api", "terminal cwd → proj")
    eq(ContextKey.key(item("iTerm2", "anything", cwd: "/Users/dev/dev/acme/")), "proj:acme", "cwd trailing slash ok")
    expect(ContextKey.key(item("iTerm2", "zsh", cwd: "/")) == nil, "root cwd → not keyable")
    // title fallback still works when cwd is absent (older shells / no shell integration)
    eq(ContextKey.key(item("iTerm2", "dev — ~/dev/acme")), "proj:acme", "terminal title fallback → proj")
    eq(ContextKey.key(item("iTerm2", "node /Users/dev/work/api")), "proj:api", "terminal abs path in title → proj")
    // cwd wins over a (possibly stale) title path
    eq(ContextKey.key(item("iTerm2", "ssh ~/old/web", cwd: "/Users/dev/work/api")), "proj:api", "cwd beats title")
    expect(ContextKey.key(item("Notes", "Grocery list")) == nil, "non-keyable item → nil")
    // the cross-app cluster link: a repo tab and its checkout share the key
    eq(ContextKey.key(item("Arc", "PR", "https://github.com/x/api")),
       ContextKey.key(item("iTerm2", "zsh", cwd: "/Users/dev/code/api")), "repo tab & its checkout share a key")
}

// MARK: ContextEngine

private func testClusterStub() {
    print("ContextEngine:")
    let items: [ContextItem] = [
        item("Arc", "PR #3", "https://github.com/acme/api/pull/3"),
        item("iTerm2", "dev — ~/dev/api"),                       // proj:api, 2nd app → clusters
        item("Google Chrome", "Gmail", "https://mail.google.com"),  // site:google.com, lone app → dropped
        item("Arc", "Board", "https://figma.com/file"),         // site:figma.com, lone → dropped
    ]
    let ctx = ContextEngine.cluster(items, overrides: ContextOverrides())
    eq(ctx.count, 1, "only the ≥2-app group survives")
    eq(ctx.first?.id, "proj:api", "surviving group is proj:api")
    eq(ctx.first?.label, "api", "derived label")
    eq(ctx.first?.apps.count, 2, "spans 2 apps")

    // user-named single-app group survives the ≥2-app filter
    let ov = ContextOverrides()
    ov.rename("site:figma.com", to: "Design")
    let ctx2 = ContextEngine.cluster(items, overrides: ov)
    expect(ctx2.contains { $0.label == "Design" }, "user-named lone group survives")

    // label precedence: user rename > AI > derived
    let ai = ["proj:api": "API & infra"]
    let ctxAI = ContextEngine.cluster(items, overrides: ContextOverrides(), aiLabels: ai)
    eq(ctxAI.first?.label, "API & infra", "AI label beats derived")
    eq(ctxAI.first?.aiLabeled, true, "AI-named context is flagged aiLabeled")
    let ov3 = ContextOverrides(); ov3.rename("proj:api", to: "My API")
    let ctxBoth = ContextEngine.cluster(items, overrides: ov3, aiLabels: ai)
    eq(ctxBoth.first { $0.id == "proj:api" }?.label, "My API", "user rename beats AI label")
    eq(ctxBoth.first { $0.id == "proj:api" }?.aiLabeled, false, "user-renamed context is NOT aiLabeled")
}

private func testOverridesStub() {
    print("ContextOverrides:")
    let ov = ContextOverrides()
    expect(ov.group(forKey: "local:3000") == nil, "no assignment by default")
    ov.assign(key: "local:3000", toGroup: "proj:api")
    eq(ov.group(forKey: "local:3000"), "proj:api", "assignment recorded")
    expect(!ov.isUserNamed("proj:api"), "not user-named until renamed/created")
    ov.rename("proj:api", to: "API work")
    expect(ov.isUserNamed("proj:api"), "rename marks user-owned")
    eq(ov.label(forGroup: "proj:api"), "API work", "label recorded")

    // assigning a localhost into a project pulls it into that cluster
    let items: [ContextItem] = [
        item("Arc", "repo", "https://github.com/x/api"),  // proj:api
        item("Chrome", "dev", "http://localhost:3000"),    // local:3000 → assigned → proj:api
    ]
    let clustered = ContextEngine.cluster(items, overrides: ov)
    eq(clustered.first?.members.count, 2, "assigned localhost joins the project")
    eq(clustered.first?.label, "API work", "user label wins over derived")
}

// MARK: ContextStore (integration)

private struct StubLabeler: ContextLabeler {
    let map: [String: String]
    func label(_ contexts: [WorkContext]) async -> [String: String] { map }
}

private func freshDefaults(_ name: String) -> UserDefaults {
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func testStoreIntegration() {
    print("ContextStore (integration):")
    let items: [ContextItem] = [
        item("Arc", "PR", "https://github.com/acme/api/pull/1"),
        item("iTerm2", "dev — ~/dev/api"),
        item("Google Chrome", "Gmail", "https://mail.google.com"),   // lone app → not a context
    ]
    let ov = ContextOverrides()
    let store = ContextStore(gatherItems: { items }, overrides: ov,
                             labeler: DeterministicLabeler(), defaults: freshDefaults("ctxtest.store"))
    store.recompute()
    eq(store.contexts.count, 1, "store clusters one cross-app context")
    eq(store.contexts.first?.label, "api", "derived label before rename")

    store.rename("proj:api", to: "API")
    eq(store.contexts.first?.label, "API", "rename reflected immediately")
    expect(ov.isUserNamed("proj:api"), "rename made the group user-owned (durable)")
}

private func testStoreAILabeling() {
    print("ContextStore (async AI labeling):")
    let items: [ContextItem] = [
        item("Arc", "repo", "https://github.com/x/api"),
        item("iTerm2", "~/dev/api"),
    ]
    let store = ContextStore(gatherItems: { items }, overrides: ContextOverrides(),
                             labeler: StubLabeler(map: ["proj:api": "Backend"]),
                             defaults: freshDefaults("ctxtest.ai"))
    var fired = 0
    store.onChange = { fired += 1 }
    store.recompute()                                              // publishes derived ("api") synchronously
    eq(store.contexts.first?.label, "api", "derived label published first")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))       // let the async labeler settle
    eq(store.contexts.first?.label, "Backend", "AI label applied after async refine")
    expect(fired >= 2, "onChange fired for both the derived and refined publishes")
}

private func testManualContexts() {
    print("Manual contexts:")
    eq(ContextKey.assignmentKey(item("Arc", "x", "https://github.com/o/api")), "proj:api", "assignmentKey uses natural key")
    eq(ContextKey.assignmentKey(item("Notes", "My plan")), "item:Notes\u{1}My plan", "keyless → item identity")
    eq(ContextStore.slug("API & Infra!"), "api-infra", "slug collapses punctuation")
    eq(ContextStore.slug("   "), "context", "empty slug → fallback")

    let items: [ContextItem] = [item("Notes", "Roadmap"), item("Arc", "Reddit", "https://reddit.com")]
    let ov = ContextOverrides()
    let store = ContextStore(gatherItems: { items }, overrides: ov,
                             labeler: DeterministicLabeler(), defaults: freshDefaults("ctxtest.manual"))
    let g = store.createContext(named: "Research")
    eq(g, "user:research", "created group id")
    store.recompute()
    expect(!store.contexts.contains { $0.id == g }, "empty user context is not shown")

    store.setMembership(items[0], in: g, member: true)   // keyless Notes item
    store.setMembership(items[1], in: g, member: true)   // a site item, pulled out of its auto-cluster
    let c = store.contexts.first { $0.id == g }
    expect(c != nil, "user context appears once it has members")
    eq(c?.members.count, 2, "both manual members present (incl. the keyless Notes window)")
    eq(c?.label, "Research", "user-given label")
    expect(store.isMember(items[0], of: g), "keyless item reports membership")

    store.setMembership(items[0], in: g, member: false)
    eq(store.contexts.first { $0.id == g }?.members.count, 1, "toggling off removes the keyless member")
    expect(store.isMember(items[1], of: g), "the other member stays")

    store.setMembership(items[1], in: g, member: false)
    expect(!store.contexts.contains { $0.id == g }, "no members → not shown")
    store.discardIfEmpty(g)
    expect(ov.label(forGroup: g) == nil, "discardIfEmpty clears the dangling name")
}

private func testUniqueContextIds() {
    print("Unique new-context ids (create ≠ replace):")
    let store = ContextStore(gatherItems: { [] }, overrides: ContextOverrides(),
                             labeler: DeterministicLabeler(), defaults: freshDefaults("ctxtest.unique"))
    let a = store.createContext(named: "New context")
    let b = store.createContext(named: "New context")
    let c = store.createContext(named: "New context")
    eq(a, "user:new-context", "first new context keeps the base id")
    expect(a != b, "second new context gets a DISTINCT id (does not replace the first)")
    expect(c != a && c != b, "third new context is distinct too")
    // renaming the first must not free its id for reuse (the id is stable, label changes)
    _ = store.rename(a, to: "Renamed")
    let d = store.createContext(named: "New context")
    expect(d != a, "a renamed context still owns its id — a later new one won't collide with it")
}

private func testPerItemAdd() {
    print("Per-item add (no sibling bleed):")
    // two iTerm shells in the SAME dir → same proj key. Adding ONE must add ONLY that one.
    let shells: [ContextItem] = [
        item("iTerm2", "shell A", cwd: "/Users/dev/dev/api"),
        item("iTerm2", "shell B", cwd: "/Users/dev/dev/api"),
    ]
    eq(ContextKey.key(shells[0]), ContextKey.key(shells[1]), "both shells share the proj key")
    let store = ContextStore(gatherItems: { shells }, overrides: ContextOverrides(),
                             labeler: DeterministicLabeler(), defaults: freshDefaults("ctxtest.peritem"))
    let g = store.createContext(named: "API")
    store.recompute()                                  // populate the snapshot (the app does this on summon)
    store.setMembership(shells[0], in: g, member: true)
    let c = store.contexts.first { $0.id == g }
    eq(c?.members.count, 1, "adding one shell adds exactly one (not the sibling)")
    eq(c?.members.first?.title, "shell A", "the right one")
    expect(store.isMember(shells[0], of: g), "added shell is a member")
    expect(!store.isMember(shells[1], of: g), "sibling shell is NOT a member")
}

private func testRemoveContext() {
    print("Remove context:")
    // an AUTO context that spans 2 apps (would normally show) → removing it suppresses it for good.
    let items: [ContextItem] = [
        item("Arc", "Wikipedia", "https://wikipedia.org"),
        item("Google Chrome", "Wikipedia", "https://wikipedia.org"),
    ]
    let store = ContextStore(gatherItems: { items }, overrides: ContextOverrides(),
                             labeler: DeterministicLabeler(), defaults: freshDefaults("ctxtest.remove"))
    store.recompute()
    expect(store.contexts.contains { $0.id == "site:wikipedia.org" }, "auto context shows before removal")
    store.removeContext("site:wikipedia.org")
    expect(!store.contexts.contains { $0.id == "site:wikipedia.org" }, "removed immediately")
    store.recompute()                                  // even a fresh scan must not bring it back
    expect(!store.contexts.contains { $0.id == "site:wikipedia.org" }, "stays removed after re-derive (ignored)")
}

// A labeler that returns a DIFFERENT name on every call — simulates the model's non-determinism,
// so we can prove the store doesn't churn names when content is unchanged.
private final class FlipLabeler: ContextLabeler {
    var calls = 0
    func label(_ contexts: [WorkContext]) async -> [String: String] {
        calls += 1
        var out: [String: String] = [:]
        for c in contexts { out[c.id] = "name\(calls)" }
        return out
    }
}

private func drain(_ s: Double = 0.4) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }

private func testStickyEvolve() {
    print("Sticky / evolve labeling:")
    var items: [ContextItem] = [
        item("Arc", "repo", "https://github.com/x/api"),
        item("iTerm2", "~/dev/api"),
    ]
    let flip = FlipLabeler()
    let store = ContextStore(gatherItems: { items }, overrides: ContextOverrides(),
                             labeler: flip, defaults: freshDefaults("ctxtest.sticky"))
    store.recompute(); drain()
    eq(store.contexts.first?.label, "name1", "named on first sight")
    eq(flip.calls, 1, "labeler called once")

    store.recompute(); drain()                         // same content → must NOT re-label
    eq(store.contexts.first?.label, "name1", "unchanged content keeps the name (no churn)")
    eq(flip.calls, 1, "labeler NOT called again for unchanged content")

    items.append(item("Google Chrome", "dash", "https://github.com/x/api"))  // composition changes (new app)
    store.recompute(); drain()
    eq(store.contexts.first?.label, "name2", "composition change → re-labeled (evolves)")
    eq(flip.calls, 2, "labeler called again only because content changed")
}

// MARK: run

@main struct TestRunner {
    static func main() {
        testKeys()
        testClusterStub()
        testOverridesStub()
        testStoreIntegration()
        testStoreAILabeling()
        testManualContexts()
        testUniqueContextIds()
        testPerItemAdd()
        testRemoveContext()
        testStickyEvolve()
        print(failures == 0 ? "\n✅ all \(checks) checks passed" : "\n❌ \(failures)/\(checks) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
