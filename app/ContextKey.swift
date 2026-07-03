import Foundation

/// A switchable item (tab / session / window) reduced to the few fields context
/// inference needs. TabRef conforms (see Adapters.swift). Kept Foundation-only and
/// protocol-based so the inference logic is unit-testable without AppKit.
protocol ContextItem {
    var app: String { get }      // owning app, e.g. "Google Chrome", "iTerm2", "Arc"
    var title: String { get }
    var url: String? { get }     // browser tabs only
    var cwd: String? { get }     // terminal working directory (iTerm), else nil
}

extension ContextItem {
    var cwd: String? { nil }     // default — only terminal adapters populate this
}

/// Extracts a normalized "context key" from an item — the shared identifier that ties
/// items across apps into one working context. Pure functions; the heart of clustering.
///
/// Key forms (namespaced so a repo never collides with a domain):
///   proj:<name>   — a project: github/gitlab/bitbucket REPO **or** a terminal's dir.
///                   Repo and dir SHARE this namespace so a repo's browser tab and its
///                   local checkout in a terminal cluster together (common case: the dir
///                   is named after the repo). The repo-vs-org-vs-dir alignment is the
///                   tunable entity-resolution choice; the AI/override layer refines it.
///   local:<port>  — localhost:PORT dev servers
///   site:<domain> — registrable domain for everything else
enum ContextKey {

    static func key(_ item: ContextItem) -> String? {
        if let url = item.url, let k = keyFromURL(url) { return k }
        // terminal: prefer the real working directory; fall back to parsing a path from the title.
        if let cwd = item.cwd, let dir = lastPathComponent(cwd) { return "proj:" + normalize(dir) }
        if let dir = terminalDir(item.title) { return "proj:" + normalize(dir) }
        return nil                                   // not keyable → won't auto-cluster
    }

    /// Per-ITEM identity, used for MANUAL add/remove so toggling one tab affects exactly that tab —
    /// not every tab that happens to share its project/site key (e.g. several iTerm shells in the
    /// same dir, or many tabs on one site). Title-based, so it follows the item.
    static func itemKey(_ item: ContextItem) -> String {
        "item:\(item.app)\u{1}\(item.title)"
    }

    /// Key used for telemetry / the cluster Ref. Natural key when there is one, else the item identity.
    static func assignmentKey(_ item: ContextItem) -> String {
        key(item) ?? itemKey(item)
    }

    // MARK: URL → key

    private static let codeHosts = ["github.com", "gitlab.com", "bitbucket.org"]

    static func keyFromURL(_ raw: String) -> String? {
        guard let c = URLComponents(string: raw), let host = c.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host == "localhost" || host == "127.0.0.1" {
            return "local:" + (c.port.map(String.init) ?? "")
        }
        let segs = c.path.split(separator: "/").map(String.init)
        if codeHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }), segs.count >= 2 {
            return "proj:" + normalize(segs[1])      // /org/REPO → project keyed by REPO
        }
        return "site:" + registrableDomain(host)
    }

    // MARK: terminal title → dir

    /// Last path component of an absolute/home path ("/Users/dev/work/api" → "api"). nil for "/" or "~".
    static func lastPathComponent(_ path: String) -> String? {
        let last = path.split(separator: "/").last.map(String.init)
        return (last?.isEmpty == false) ? last : nil
    }

    /// Pull a directory name out of a terminal session title if one is present
    /// (e.g. "dev — ~/dev/acme" or "node /Users/x/work/api"). Best-effort fallback when the
    /// adapter couldn't read the real cwd.
    static func terminalDir(_ title: String) -> String? {
        for token in title.split(whereSeparator: { " \t—–:|".contains($0) }) {
            let t = String(token)
            if t.hasPrefix("~/") || t.hasPrefix("/") { if let d = lastPathComponent(t) { return d } }
        }
        return nil
    }

    // MARK: helpers

    /// Last two labels of a host (mail.google.com → google.com). Deliberately simple;
    /// good enough to fold subdomains of the same site into one key.
    static func registrableDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    /// Canonicalize a name for entity resolution: lowercase, strip a trailing ".git", and trim
    /// surrounding punctuation. Intentionally conservative — we normalize casing/punctuation only,
    /// NOT semantics (so "api" and "api-v2" stay distinct repos).
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        if t.hasSuffix(".git") { t.removeLast(4) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -_./"))
        return t
    }

    /// Human label for a raw key when the user hasn't named the context.
    static func displayLabel(_ key: String) -> String {
        if let r = key.range(of: ":") {
            let body = String(key[r.upperBound...])
            return body.isEmpty ? String(key[..<r.lowerBound]) : body
        }
        return key
    }
}
