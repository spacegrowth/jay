import AppKit
import ApplicationServices
import Contacts

// MARK: - Model

struct TabRef {
    let app: String          // owning app
    let group: String        // section label: Arc Space, Chrome window, or app name
    let title: String
    let url: String?         // for browser tabs — drives the favicon
    let subtitle: String?    // optional secondary line under the title (e.g. VS Code's folder). Only plugins set it; built-in adapters leave it nil.
    let isActive: Bool       // plugin's frontmost/active item (e.g. VS Code's currently-open file). Built-in adapters leave it false.
    let folder: String?      // Arc folder name (sub-group under a Space), else nil
    let groupIcon: String?   // Arc Space icon NAME as stored by Arc (e.g. "planet"), else nil
    let splitId: String?     // Arc split-view id this tab belongs to, else nil
    let splitTitle: String?  // that split's title ("" if untitled), else nil
    let incognito: Bool      // private/incognito tab (shows a glyph)
    let cwd: String?         // terminal working directory (iTerm) — drives context clustering
    let leadImage: NSImage?  // custom leading icon (e.g. a Messages contact photo), else app icon/favicon
    let activate: () -> Void // focus this context
    let close: (() -> Void)? // close this tab silently (nil = not supported → no × / ⌘W no-op)

    init(app: String, group: String, title: String, url: String?,
         subtitle: String? = nil, isActive: Bool = false,
         folder: String? = nil, groupIcon: String? = nil,
         splitId: String? = nil, splitTitle: String? = nil,
         incognito: Bool = false, cwd: String? = nil, leadImage: NSImage? = nil,
         close: (() -> Void)? = nil, activate: @escaping () -> Void) {
        self.app = app; self.group = group; self.title = title
        self.subtitle = subtitle; self.isActive = isActive
        self.url = url; self.folder = folder; self.groupIcon = groupIcon
        self.splitId = splitId; self.splitTitle = splitTitle
        self.incognito = incognito; self.cwd = cwd; self.leadImage = leadImage
        self.close = close; self.activate = activate
    }
}

// TabRef already carries app/title/url/cwd — the fields context inference needs.
extension TabRef: ContextItem {}

// MARK: - AppleScript helpers (rich adapters)

private func osaList(_ src: String) -> [String] {
    var err: NSDictionary?
    guard let res = NSAppleScript(source: src)?.executeAndReturnError(&err), err == nil,
          res.numberOfItems > 0 else { return [] }
    return (1...res.numberOfItems).compactMap { res.atIndex($0)?.stringValue }
}
private func osaString(_ src: String) -> String? {
    var err: NSDictionary?
    guard let s = NSAppleScript(source: src) else { return nil }
    return s.executeAndReturnError(&err).stringValue
}
private func osaInt(_ src: String) -> Int {
    var err: NSDictionary?
    guard let s = NSAppleScript(source: src) else { return 0 }
    return Int(s.executeAndReturnError(&err).int32Value)
}
/// A focus action that activates a scriptable app and runs a body in its dictionary.
private func appAction(_ app: String, _ body: String) -> () -> Void {
    let src = "tell application \"\(app)\"\nactivate\n\(body)\nend tell"
    return { NSAppleScript(source: src)?.executeAndReturnError(nil) }
}
/// Run AppleScript off-main WITHOUT activating the app (silent edit, e.g. closing a tab).
private func runSilent(_ src: String) {
    DispatchQueue.global(qos: .userInitiated).async { NSAppleScript(source: src)?.executeAndReturnError(nil) }
}

// MARK: - browser actions (new tab)

// Used for the ⌘T new-tab action (keystroke-based, so it works even for browsers we
// can't enumerate tabs from, like Firefox/Zen). Tab *listing* is still limited to the
// scriptable ones (Chrome/Safari/Arc) — Firefox-family expose no AppleScript tab API.
let browserApps: Set<String> = ["Google Chrome", "Arc", "Safari", "Brave Browser",
                                "Microsoft Edge", "Chromium", "Vivaldi",
                                "Firefox", "Zen", "Zen Browser", "LibreWolf"]
func isBrowser(_ app: String) -> Bool { browserApps.contains(app) }

/// Open a new tab (or, if `private`, a new private/incognito window — browsers have no
/// per-tab incognito) in a browser. Prefers the browser's OWN scripting (we already hold
/// its Automation permission from tab enumeration); falls back to a System-Events keystroke
/// only where the app can't script it. Off-main; activates so the cursor lands.
func openNewBrowserTab(_ app: String, private isPrivate: Bool = false) {
    var body = ""
    switch app {
    case "Google Chrome", "Brave Browser", "Microsoft Edge", "Chromium", "Vivaldi":
        body = isPrivate
            ? "make new window with properties {mode:\"incognito\"}"
            : "if (count windows) is 0 then\nmake new window\nelse\ntell front window to make new tab\nend if"
    case "Safari":
        if !isPrivate { body = "tell front window to make new tab" }   // private Safari → keystroke fallback
    // Arc: its `make new tab` AppleScript is unreliable, but the ⌘T keystroke works
    // (confirmed: ⌘⇧N private works) — so let Arc fall through to the keystroke path.
    default: break
    }
    let src: String
    if body.isEmpty {                                                  // fallback: activate + ⌘T / ⌘⇧N
        let keys = isPrivate ? "keystroke \"n\" using {command down, shift down}" : "keystroke \"t\" using command down"
        src = "tell application \"\(app)\" to activate\ndelay 0.12\ntell application \"System Events\" to \(keys)"
    } else {
        src = "tell application \"\(app)\"\nactivate\n\(body)\nend tell"
    }
    DispatchQueue.global(qos: .userInitiated).async {
        NSAppleScript(source: src)?.executeAndReturnError(nil)
    }
}

// MARK: - Rich per-app enumerators (tab depth)

/// Map each Arc tab id → its folder name, read from Arc's on-disk sidebar store.
/// Arc doesn't expose folders to AppleScript, but the tab `id` matches between the
/// live scripting layer and this file, so we join on it. The folder is the nearest
/// `list`-kind ancestor walking up `parentID`. Best-effort: any parse failure or a
/// just-created tab simply yields no folder, and the adapter falls back to flat.
private func arcFolders() -> [String: String] {
    let path = ("~/Library/Application Support/Arc/StorableSidebar.json" as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sidebar = root["sidebar"] as? [String: Any],
          let containers = sidebar["containers"] as? [Any] else { return [:] }

    // The real tab/folder tree lives in the container that has an "items" array.
    var byId: [String: [String: Any]] = [:]
    for c in containers {
        guard let cd = c as? [String: Any], let items = cd["items"] as? [Any] else { continue }
        for it in items {
            if let o = it as? [String: Any], let id = o["id"] as? String { byId[id] = o }
        }
    }
    guard !byId.isEmpty else { return [:] }

    func kind(_ o: [String: Any]) -> String { (o["data"] as? [String: Any])?.keys.first ?? "" }

    // Walk parentID upward to the first folder (`list`) and return its title.
    func folderOf(_ id: String) -> String? {
        var cur = byId[id]
        var hops = 0
        while let o = cur, hops < 64 {
            hops += 1
            guard let pid = o["parentID"] as? String, let parent = byId[pid] else { return nil }
            if kind(parent) == "list" { return (parent["title"] as? String) ?? "Folder" }
            cur = parent
        }
        return nil
    }

    var map: [String: String] = [:]
    for (id, o) in byId where kind(o) == "tab" {
        if let f = folderOf(id) { map[id] = f }
    }
    return map
}

/// Map each Arc tab id → the split-view it belongs to (id + title), for tabs whose
/// direct parent is a `splitView`. Title is "" for untitled (often mixed-site) splits.
private func arcSplits() -> [String: (id: String, title: String)] {
    let path = ("~/Library/Application Support/Arc/StorableSidebar.json" as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sidebar = root["sidebar"] as? [String: Any],
          let containers = sidebar["containers"] as? [Any] else { return [:] }
    var byId: [String: [String: Any]] = [:]
    for c in containers {
        guard let cd = c as? [String: Any], let items = cd["items"] as? [Any] else { continue }
        for it in items { if let o = it as? [String: Any], let id = o["id"] as? String { byId[id] = o } }
    }
    func kind(_ o: [String: Any]) -> String { (o["data"] as? [String: Any])?.keys.first ?? "" }
    var map: [String: (String, String)] = [:]
    for (id, o) in byId where kind(o) == "tab" {
        if let pid = o["parentID"] as? String, let p = byId[pid], kind(p) == "splitView" {
            map[id] = (pid, (p["title"] as? String) ?? "")
        }
    }
    return map
}

/// Resolves Arc Space icons to a real emoji using ARC'S OWN bundled table —
/// `ARC_Emojis.bundle/emojis.json` inside Arc.app (located via bundle id, so no
/// hardcoded path). Built once. An icon name like "pizza" is matched against the
/// table's aliases → tags → description words. Nothing about a specific machine.
private final class ArcEmoji {
    static let shared = ArcEmoji()
    private var alias: [String: String] = [:]
    private var tag: [String: String] = [:]
    private var descWord: [String: String] = [:]
    private var sfEmoji: [String: String] = [:]   // SF Symbol name → emoji (Arc's table)

    private init() {
        guard let arc = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "company.thebrowser.Browser") else { return }
        let res = arc.appendingPathComponent("Contents/Resources")
        // emoji-named icons (pizza, planet…)
        if let data = try? Data(contentsOf: res.appendingPathComponent("ARC_Emojis.bundle/Contents/Resources/emojis.json")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in arr {
                guard let emoji = e["emoji"] as? String else { continue }
                for a in (e["aliases"] as? [String] ?? []) where alias[a.lowercased()] == nil { alias[a.lowercased()] = emoji }
                for t in (e["tags"] as? [String] ?? []) where tag[t.lowercased()] == nil { tag[t.lowercased()] = emoji }
                for w in (e["description"] as? String ?? "").lowercased().split(separator: " ") {
                    let s = String(w); if descWord[s] == nil { descWord[s] = emoji }
                }
            }
        }
        // SF-Symbol-named icons (chatBubbleEllipses…) → emoji, via Arc's own SF↔emoji table
        if let data = try? Data(contentsOf: res.appendingPathComponent("ARCFoundation_ARCFoundationBase.bundle/Contents/Resources/SFSymbolEmojiLookupTable.json")),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            sfEmoji = map
        }
    }

    /// Split a camelCase or dotted name into lightly-stemmed lowercase tokens.
    private func tokens(_ s: String) -> Set<String> {
        var spaced = ""
        for ch in s { if ch.isUppercase { spaced.append(" ") }; spaced.append(ch) }
        return Set(spaced.replacingOccurrences(of: ".", with: " ").lowercased()
            .split(separator: " ").map { w -> String in
                var t = String(w)
                if t.hasSuffix("es") { t.removeLast(2) } else if t.hasSuffix("s") { t.removeLast() }
                return t
            }.filter { !$0.isEmpty })
    }

    /// Best emoji for an Arc SF-symbol-style icon name, by token overlap with Arc's table.
    /// Deterministic: ties break on fewer tokens, then highest key name (stable across runs).
    private func sfMatch(_ name: String) -> String? {
        let nt = tokens(name); guard !nt.isEmpty else { return nil }
        var best: (score: Int, simple: Int, key: String, emoji: String)?
        for (key, emoji) in sfEmoji {
            let inter = nt.intersection(tokens(key)).count
            guard inter > 0 else { continue }
            let cand = (inter, -tokens(key).count, key, emoji)
            if best == nil || (cand.0, cand.1, cand.2) > (best!.score, best!.simple, best!.key) {
                best = cand
            }
        }
        return best?.emoji
    }

    /// Resolve one space's iconType dict to an emoji glyph, or nil.
    func resolve(_ iconType: [String: Any]) -> String? {
        if let e = iconType["emoji_v2"] as? String, !e.isEmpty { return e }   // Arc stored the glyph directly
        if let n = iconType["emoji"] as? Int, let sc = UnicodeScalar(n) { return String(sc) }
        if let name = iconType["icon"] as? String {
            let lname = name.lowercased()
            if let e = alias[lname] ?? tag[lname] ?? descWord[lname] { return e }  // emoji-named
            return sfMatch(name)                                                   // SF-symbol-named
        }
        return nil
    }
}

/// Map each Arc Space title → its resolved emoji glyph (structural read of the
/// sidebar store; spaces with no resolvable icon are simply absent).
private func arcSpaceEmojis() -> [String: String] {
    let path = ("~/Library/Application Support/Arc/StorableSidebar.json" as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sidebar = root["sidebar"] as? [String: Any],
          let containers = sidebar["containers"] as? [Any] else { return [:] }
    var map: [String: String] = [:]
    for c in containers {
        guard let cd = c as? [String: Any], let spaces = cd["spaces"] as? [Any] else { continue }
        for sp in spaces {
            guard let s = sp as? [String: Any], let title = s["title"] as? String,
                  let custom = s["customInfo"] as? [String: Any],
                  let iconType = custom["iconType"] as? [String: Any] else { continue }
            if let emoji = ArcEmoji.shared.resolve(iconType) { map[title] = emoji }
        }
    }
    return map
}

/// Index of Arc's first NON-incognito window. Arc's spaces are global (shared across regular
/// windows) but incognito windows have no spaces and aren't scriptable, so reading `front window`
/// breaks whenever an incognito window is frontmost. We always read from a regular window instead,
/// so the snapshot is stable regardless of which window is front. 0 = only incognito windows open.
/// Only touches the `incognito` property (element access on incognito windows errors).
func arcRegularWindow() -> Int {
    osaInt("""
    tell application "Arc"
      repeat with i from 1 to (count windows)
        if not (incognito of window i) then return i
      end repeat
      return 0
    end tell
    """)
}
// Tab actions recompute the regular window at call time, so window reordering between scan and
// click can't target the wrong window. Space index is consistent across regular windows.
private func arcSelectTab(space s: Int, tab t: Int) {
    let w = arcRegularWindow(); guard w > 0 else { return }
    NSAppleScript(source: "tell application \"Arc\"\nactivate\ntell window \(w) to tell space \(s) to select tab \(t)\nend tell")?
        .executeAndReturnError(nil)
}
private func arcCloseTab(space s: Int, tab t: Int) {
    let w = arcRegularWindow(); guard w > 0 else { return }
    runSilent("tell application \"Arc\" to tell window \(w) to tell space \(s) to close tab \(t)")
}

private func arcContexts() -> [TabRef] {
    let w = arcRegularWindow()
    guard w > 0 else { return [] }                 // only incognito windows open → nothing scriptable
    let spaces = osaList("tell application \"Arc\" to get name of spaces of window \(w)")
    let folders = arcFolders()
    let splits = arcSplits()
    let spaceIcons = arcSpaceEmojis()
    var refs: [TabRef] = []
    for (si, sname) in spaces.enumerated() {
        let s = si + 1
        let titles = osaList("tell application \"Arc\" to get title of tabs of space \(s) of window \(w)")
        let urls = osaList("tell application \"Arc\" to get URL of tabs of space \(s) of window \(w)")
        let ids = osaList("tell application \"Arc\" to get id of tabs of space \(s) of window \(w)")
        let spaceIcon = spaceIcons[sname]

        // Build each tab keeping its true AppleScript index for selection…
        var loose: [TabRef] = []                 // tabs not in any folder
        var foldered: [(folder: String, ref: TabRef)] = []
        for (ti, title) in titles.enumerated() {
            let folder = ti < ids.count ? folders[ids[ti]] : nil
            let split = ti < ids.count ? splits[ids[ti]] : nil
            let ref = TabRef(app: "Arc", group: "Arc · \(sname)", title: title,
                url: ti < urls.count ? urls[ti] : nil, folder: folder, groupIcon: spaceIcon,
                splitId: split?.id, splitTitle: split?.title,
                close: { arcCloseTab(space: s, tab: ti + 1) },
                activate: { arcSelectTab(space: s, tab: ti + 1) })
            if let f = folder { foldered.append((f, ref)) } else { loose.append(ref) }
        }
        // Order: folders first (grouped, first-appearance), THEN loose tabs (panel draws a rule between).
        var folderOrder: [String] = []
        for fr in foldered where !folderOrder.contains(fr.folder) { folderOrder.append(fr.folder) }
        for f in folderOrder { refs += foldered.filter { $0.folder == f }.map { $0.ref } }
        refs += loose
    }
    return refs
}

// MARK: - Domain clustering (Chrome / Safari)
//
// Chrome and Safari don't expose their tab GROUPS to AppleScript, so the only useful
// organizational axis is the URL. We cluster tabs by registrable domain (eTLD+1-ish),
// so all github.com / all google.com tabs group together — biggest clusters first.

private func registrableDomain(_ urlStr: String?) -> String {
    guard let u = urlStr, let comps = URLComponents(string: u),
          let host = comps.host, !host.isEmpty else { return "Other" }
    if let s = comps.scheme, s != "http", s != "https" { return "Other" }   // chrome://, about:, file:…
    var h = host
    if h.hasPrefix("www.") { h.removeFirst(4) }
    let parts = h.split(separator: ".").map(String.init)
    if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) { return h }   // IPv4 → keep whole
    guard parts.count > 2 else { return h }
    // keep a 3rd label when the 2nd-to-last is a common 2-level public suffix (co.uk, com.au…)
    let twoLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]
    let tail = twoLevel.contains(parts[parts.count - 2]) ? 3 : 2
    return parts.suffix(tail).joined(separator: ".")
}

/// Order tabs so same-domain tabs are contiguous; domains sorted by size (desc), then name.
/// Each ref's `group` is set to its domain so the panel renders a header per cluster.
private func clusterByDomain(_ tabs: [(domain: String, ref: TabRef)]) -> [TabRef] {
    var counts: [String: Int] = [:]
    for t in tabs { counts[t.domain, default: 0] += 1 }
    let domains = counts.keys.sorted { a, b in counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a < b }
    return domains.flatMap { d in tabs.filter { $0.domain == d }.map { $0.ref } }
}

// Chromium browsers (Chrome, Edge, Brave, Vivaldi, …) all expose the SAME AppleScript dictionary,
// so one parameterized adapter covers them all — just the app name changes.
private func chromiumContexts(_ app: String) -> [TabRef] {
    let n = osaInt("tell application \"\(app)\" to count windows")
    guard n > 0 else { return [] }
    var tabs: [(domain: String, ref: TabRef)] = []
    for i in 1...n {
        guard let wid = osaString("tell application \"\(app)\" to get id of window \(i) as string")
        else { continue }
        let incog = osaString("tell application \"\(app)\" to get mode of window \(i)") == "incognito"
        let titles = osaList("tell application \"\(app)\" to get title of tabs of window \(i)")
        let urls = osaList("tell application \"\(app)\" to get URL of tabs of window \(i)")
        for (ti, title) in titles.enumerated() {
            let url = ti < urls.count ? urls[ti] : nil
            let dom = registrableDomain(url)
            let ref = TabRef(app: app, group: dom, title: title, url: url, incognito: incog,
                close: { runSilent("tell application \"\(app)\" to close tab \(ti + 1) of window id \(wid)") },
                activate: appAction(app,
                    "set active tab index of window id \(wid) to \(ti + 1)\nset index of window id \(wid) to 1"))
            tabs.append((dom, ref))
        }
    }
    return clusterByDomain(tabs)
}

private func safariContexts() -> [TabRef] {
    let titles = osaList("tell application \"Safari\" to get name of tabs of front window")
    let urls = osaList("tell application \"Safari\" to get URL of tabs of front window")
    let tabs: [(domain: String, ref: TabRef)] = titles.enumerated().map { (ti, title) in
        let url = ti < urls.count ? urls[ti] : nil
        let dom = registrableDomain(url)
        let ref = TabRef(app: "Safari", group: dom, title: title, url: url,
            close: { runSilent("tell application \"Safari\" to close tab \(ti + 1) of front window") },
            activate: appAction("Safari", "tell front window to set current tab to tab \(ti + 1)"))
        return (dom, ref)
    }
    return clusterByDomain(tabs)
}

private func itermContexts() -> [TabRef] {
    let titles = osaList("tell application \"iTerm2\" to get name of current session of tabs of current window")
    // Mark the active session by its UNIQUE id (titles are dynamic/duplicable → unreliable to match on).
    let ids = osaList("tell application \"iTerm2\" to get id of current session of tabs of current window")
    let activeId = osaString("tell application \"iTerm2\" to get id of current session of current window") ?? ""
    // Per-tab working directory (iTerm's "path" session variable, index-aligned with titles).
    // The `... of t` accessor form is rejected by iTerm, so we tell each session directly.
    let cwds = osaList("""
    tell application "iTerm2"
      set out to {}
      tell current window
        repeat with t in tabs
          tell current session of t
            set end of out to (variable named "path")
          end tell
        end repeat
      end tell
    end tell
    return out
    """)
    return titles.enumerated().map { (ti, title) in
        TabRef(app: "iTerm2", group: "iTerm2", title: title, url: nil,
               isActive: ti < ids.count && !activeId.isEmpty && ids[ti] == activeId,
               cwd: ti < cwds.count ? cwds[ti] : nil,
               activate: appAction("iTerm2", "tell current window to select tab \(ti + 1)"))
    }
}

// MARK: - Media & Messages adapters
//
// Spotify and Music expose only the LIVE track over AppleScript — there is no history term in
// either dictionary (verified against their sdef) — so those surface "Now Playing". Music also
// has a built-in "Recently Played" smart playlist we read. Messages: a chat id is
// "service;type;handle", so the recent-conversation list (already recency-ordered) and each
// handle come straight from `id of chats` — Automation permission ONLY, no Full Disk Access,
// and no message text is ever read.

private func spotifyContexts() -> [TabRef] {
    guard isRunning("Spotify") else { return [] }
    guard let name = osaString("tell application \"Spotify\" to name of current track"), !name.isEmpty else { return [] }
    let artist = osaString("tell application \"Spotify\" to artist of current track") ?? ""
    return [TabRef(app: "Spotify", group: "Now Playing",
                   title: artist.isEmpty ? name : "\(name) — \(artist)",
                   url: nil, activate: appAction("Spotify", ""))]
}

private func musicContexts() -> [TabRef] {
    guard isRunning("Music") else { return [] }
    var refs: [TabRef] = []
    if let name = osaString("tell application \"Music\" to name of current track"), !name.isEmpty {
        let artist = osaString("tell application \"Music\" to artist of current track") ?? ""
        refs.append(TabRef(app: "Music", group: "Now Playing",
                           title: artist.isEmpty ? name : "\(name) — \(artist)",
                           url: nil, activate: appAction("Music", "")))
    }
    // Music's built-in "Recently Played" smart playlist. Two list reads (names, artists) instead of
    // per-track property fetches keep it fast; an absent/empty playlist just yields nothing.
    func recents(_ field: String) -> [String] {
        osaList("tell application \"Music\"\ntry\nget \(field) of tracks of playlist \"Recently Played\"\non error\nreturn {}\nend try\nend tell")
    }
    let names = recents("name"), artists = recents("artist")
    for (i, name) in names.prefix(12).enumerated() where !name.isEmpty {
        let artist = i < artists.count ? artists[i] : ""
        refs.append(TabRef(app: "Music", group: "Recently Played",
                           title: artist.isEmpty ? name : "\(name) — \(artist)",
                           url: nil, activate: appAction("Music", "")))
    }
    return refs
}

/// Resolves Messages handles (phone / email) → contact display names. Built ONCE from the address
/// book in the background as a normalized map, so the summon path is only a dict lookup — no
/// per-row Contacts queries. Rebuilds on Contacts changes; falls back to the raw handle when
/// unauthorized or unmatched. Needs the Contacts permission (requested at launch).
final class ContactNames {
    static let shared = ContactNames()
    private var names: [String: String] = [:]
    private var imgs: [String: NSImage] = [:]
    private var built = false
    private let lock = NSLock()

    private init() {
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) {
            [weak self] _ in self?.warm()
        }
    }

    /// Prompt once if undecided; (re)build the map whenever we have access.
    func requestAccess() {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: CNContactStore().requestAccess(for: .contacts) { [weak self] ok, _ in if ok { self?.warm() } }
        case .authorized:    warm()
        default:             break
        }
    }

    private func warm() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        DispatchQueue.global(qos: .utility).async { self.build() }
    }

    private func build() {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                    CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
                    CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        var nm: [String: String] = [:], im: [String: NSImage] = [:]
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let display = !full.isEmpty ? full : (!c.nickname.isEmpty ? c.nickname : c.organizationName)
            guard !display.isEmpty else { return }
            let img = c.thumbnailImageData.flatMap { NSImage(data: $0) }     // only photo-having contacts
            func put(_ k: String) { nm[k] = display; if let img { im[k] = img } }
            for p in c.phoneNumbers { if let k = Self.phoneKey(p.value.stringValue) { put(k) } }
            for e in c.emailAddresses { put("e:" + (e.value as String).lowercased()) }
        }
        lock.lock(); names = nm; imgs = im; built = true; lock.unlock()
    }

    /// Handle → lookup key: email lowercased; phone by digits — short codes (e.g. 34423) keyed
    /// EXACTLY, longer numbers by last 10 so "+1 (817) 773-8937" and "8177738937" collide.
    private static func key(for handle: String) -> String? {
        if handle.contains("@") { return "e:" + handle.lowercased() }
        return phoneKey(handle)
    }
    private static func phoneKey(_ s: String) -> String? {
        let d = s.filter(\.isNumber)
        guard !d.isEmpty else { return nil }
        return "p:" + (d.count >= 10 ? String(d.suffix(10)) : d)
    }

    /// Cached lookups — nil if unauthorized, not built yet, or no match.
    func name(for handle: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return built ? Self.key(for: handle).flatMap { names[$0] } : nil
    }
    func image(for handle: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return built ? Self.key(for: handle).flatMap { imgs[$0] } : nil
    }
}

/// Format a US phone handle for display; leave emails / short codes / intl numbers as-is.
/// Used as the fallback when a handle has no matching contact.
private func prettyPhone(_ h: String) -> String {
    if h.contains("@") { return h }
    let d = Array(h.filter { $0.isNumber })
    if d.count == 11, d.first == "1" { return "(\(String(d[1...3]))) \(String(d[4...6]))-\(String(d[7...10]))" }
    if d.count == 10 { return "(\(String(d[0...2]))) \(String(d[3...5]))-\(String(d[6...9]))" }
    return h
}

private func messagesContexts() -> [TabRef] {
    guard isRunning("Messages") else { return [] }
    // A chat id is "service;type;handle": type "+" = group, "-" = 1:1; the list is recency-ordered.
    // Automation permission only — no Full Disk Access, no chat.db, no message text. Groups carry no
    // AppleScript name, so we label them by participants (resolved to contact names), fetched per
    // group only within the shown window (index matches the ordered `chats` list).
    let ids = osaList("tell application \"Messages\" to get id of chats")
    let focusMessages = { _ = NSWorkspace.shared.runningApplications.first { $0.localizedName == "Messages" }?.activate() }
    var seen = Set<String>(); var refs: [TabRef] = []
    for (idx, id) in ids.enumerated() {
        let parts = id.components(separatedBy: ";")
        let isGroup = parts.count >= 2 && parts[1] == "+"
        let key = parts.last ?? id                                             // handle (1:1) or group GUID
        guard !key.isEmpty, seen.insert(key).inserted else { continue }        // collapse SMS+iMessage / dup groups
        if isGroup {
            let handles = osaList("tell application \"Messages\" to get handle of participants of chat \(idx + 1)")
            let named = handles.prefix(3).map { ContactNames.shared.name(for: $0) ?? prettyPhone($0) }
            var label = named.joined(separator: ", ")
            if handles.count > 3 { label += " +\(handles.count - 3)" }
            refs.append(TabRef(app: "Messages", group: "Messages",
                               title: label.isEmpty ? "Group message" : label, url: nil,
                               activate: { focusMessages() }))
        } else {
            let handle = key
            refs.append(TabRef(app: "Messages", group: "Messages",
                               title: ContactNames.shared.name(for: handle) ?? prettyPhone(handle), url: nil,
                               leadImage: ContactNames.shared.image(for: handle), activate: {
                let enc = handle.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? handle
                if let u = URL(string: "imessage://\(enc)") { NSWorkspace.shared.open(u) }   // open that 1:1
                else { focusMessages() }
            }))
        }
        if refs.count >= 15 { break }              // recent-jump window (also the search reach)
    }
    return refs
}

/// "Jane Doe <jane@x.com>" → "Jane Doe"; a bare address → itself.
private func senderName(_ s: String) -> String {
    guard let lt = s.firstIndex(of: "<") else { return s }
    let name = s[..<lt].trimmingCharacters(in: .whitespaces)
                       .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return name.isEmpty ? s : name
}

private func mailContexts() -> [TabRef] {
    guard isRunning("Mail") else { return [] }
    // Recent Inbox messages (subject + sender). Two bulk reads instead of per-message fetches keep it
    // fast; guarded for empty/small inboxes. Selecting opens that message (Mail activates regardless).
    func read(_ field: String) -> [String] {
        osaList("""
            tell application "Mail"
              try
                set n to count messages of inbox
                if n is 0 then return {}
                if n > 15 then set n to 15
                return \(field) of messages 1 thru n of inbox
              on error
                return {}
              end try
            end tell
            """)
    }
    let subjects = read("subject"), senders = read("sender")
    var refs: [TabRef] = []
    for (i, subject) in subjects.prefix(15).enumerated() {
        let who = i < senders.count ? senderName(senders[i]) : ""
        let title = subject.isEmpty ? "(no subject)" : subject
        refs.append(TabRef(app: "Mail", group: "Inbox",
                           title: who.isEmpty ? title : "\(title)  —  \(who)", url: nil,
                           activate: appAction("Mail", "open message \(i + 1) of inbox")))
    }
    return refs
}

// MARK: - Registry

struct Adapter { let app: String; let enumerate: () -> [TabRef] }

// Firefox-family browsers (no AppleScript tabs, no CDP) — handled via the Accessibility tree.
let AX_BROWSERS = ["Zen", "Firefox"]

// Chromium-family browsers sharing Chrome's AppleScript dictionary — one adapter each, same code.
let CHROMIUM_BROWSERS = ["Google Chrome", "Microsoft Edge", "Brave Browser", "Vivaldi"]

let ADAPTERS: [Adapter] = [
    Adapter(app: "Arc",    enumerate: arcContexts),
    Adapter(app: "Safari", enumerate: safariContexts),
    Adapter(app: "iTerm2", enumerate: itermContexts),
    Adapter(app: "Spotify",  enumerate: spotifyContexts),    // Now Playing (AppleScript — no history term)
    Adapter(app: "Music",    enumerate: musicContexts),      // Now Playing + Recently Played smart playlist
    Adapter(app: "Messages", enumerate: messagesContexts),   // recent conversations via AppleScript (Automation only)
    Adapter(app: "Mail",     enumerate: mailContexts),       // recent Inbox messages (subject + sender)
    // Hard or third-party targets without a native adapter are handled as external plugins (see PluginHost).
] + CHROMIUM_BROWSERS.map { name in Adapter(app: name, enumerate: { chromiumContexts(name) }) }
  + AX_BROWSERS.map { name in Adapter(app: name, enumerate: { axBrowserContexts(name) }) }

private let RICH_APPS = Set(ADAPTERS.map { $0.app })

// MARK: - Generic fallback via the Accessibility API (fast, no AppleScript)
//
// Every other regular app, at window level. Pure AX (AXUIElement) — in-process,
// fast, and needs ONLY the Accessibility permission (no "control System Events").

private func genericContexts() -> [TabRef] {
    // Skip apps handled elsewhere: built-in adapters AND any app an enabled plugin covers — otherwise
    // the plugin's items and the generic window entry BOTH show (e.g. Terminal appears twice).
    let covered = RICH_APPS.union(PluginHost.statuses().filter { $0.enabled }.compactMap { $0.targetApp })
    var refs: [TabRef] = []
    for running in NSWorkspace.shared.runningApplications {
        guard running.activationPolicy == .regular,                 // real UI apps only (excludes us: accessory)
              let name = running.localizedName, !covered.contains(name) else { continue }
        let appEl = AXUIElementCreateApplication(running.processIdentifier)
        var wv: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wv) == .success,
              let windows = wv as? [AXUIElement] else { continue }
        for win in windows {
            var tv: AnyObject?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &tv)
            let title = (tv as? String) ?? ""
            let runApp = running
            refs.append(TabRef(app: name, group: name, title: title.isEmpty ? name : title, url: nil,
                activate: {
                    runApp.activate()
                    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                }))
        }
    }
    return refs
}

// MARK: - AX browser adapter (Firefox / Zen)
//
// Firefox-family browsers have no AppleScript tab support and dropped CDP for WebDriver BiDi — but
// their tab strip lives in the Accessibility tree: each tab is an AXRadioButton whose title is the
// page title, and pressing it (after raising its window) switches to it. Reuses the app's existing
// Accessibility permission — no debug port, no extension, no relaunch. Title only (no per-tab URL).

private func axAttr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
private func axRole(_ e: AXUIElement) -> String { (axAttr(e, kAXRoleAttribute as String) as? String) ?? "" }
private func axTitle(_ e: AXUIElement) -> String {
    if let t = axAttr(e, kAXTitleAttribute as String) as? String, !t.isEmpty { return t }
    return (axAttr(e, kAXDescriptionAttribute as String) as? String) ?? ""
}
private func axSelected(_ e: AXUIElement) -> Bool { ((axAttr(e, kAXValueAttribute as String) as? NSNumber)?.intValue ?? 0) == 1 }
private func axChildren(_ e: AXUIElement) -> [AXUIElement] { (axAttr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
/// Whether an element is actually rendered on some display. Zen keeps tabs from OTHER workspaces
/// in the AX tree but positioned off-screen — and AXPress can't switch to a tab whose workspace
/// isn't active. So we only surface on-screen tabs (current workspace + pinned essentials), which
/// are the ones we can actually activate. Uses display bounds (top-left global, same as AX coords)
/// so it's correct on multi-monitor layouts (a left monitor has negative x).
private func axOnScreen(_ e: AXUIElement) -> Bool {
    guard let pvRaw = axAttr(e, kAXPositionAttribute as String),
          let svRaw = axAttr(e, kAXSizeAttribute as String),
          CFGetTypeID(pvRaw) == AXValueGetTypeID(), CFGetTypeID(svRaw) == AXValueGetTypeID()
    else { return false }
    let pv = pvRaw as! AXValue, sv = svRaw as! AXValue   // type-checked just above
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv, .cgPoint, &p)
    AXValueGetValue(sv, .cgSize, &s)
    guard s.width > 1, s.height > 1 else { return false }
    let c = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    for id in ids where CGDisplayBounds(id).contains(c) { return true }
    return false
}
private func axWindowOf(_ e: AXUIElement) -> AXUIElement? {
    var cur = e
    for _ in 0..<40 {
        if axRole(cur) == "AXWindow" { return cur }
        guard let p = axAttr(cur, kAXParentAttribute as String),
              CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        cur = p as! AXUIElement   // type-checked just above
    }
    return nil
}

/// Collect tab elements (titled AXRadioButtons) from a browser's chrome, pruning the huge AXWebArea
/// page-content subtrees so the walk stays cheap.
private func collectAXTabs(_ root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        if depth > 18 { return }
        let r = axRole(e)
        if r == "AXWebArea" { return }                                  // skip page content (huge, irrelevant)
        if r == "AXRadioButton" { if !axTitle(e).isEmpty { out.append(e) }; return }
        for c in axChildren(e) { walk(c, depth + 1) }
    }
    walk(root, 0)
    return out
}

/// One TabRef per unique tab title. The tree exposes tabs more than once (mirrored across windows /
/// pinned strips), so dedup by title. Activation re-finds by title at click time.
private func axBrowserContexts(_ appName: String) -> [TabRef] {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else { return [] }
    let pid = app.processIdentifier
    var seen = Set<String>(), refs: [TabRef] = []
    for e in collectAXTabs(AXUIElementCreateApplication(pid)) {
        let t = axTitle(e)
        if t.isEmpty || !axOnScreen(e) || seen.contains(t) { continue }   // only switchable (on-screen) tabs
        seen.insert(t)
        refs.append(TabRef(app: appName, group: appName, title: t, url: nil,
                           activate: { activateAXTab(pid: pid, title: t) }))
    }
    if refs.isEmpty {                                                   // AX found nothing → at least surface the app
        refs.append(TabRef(app: appName, group: appName, title: appName, url: nil,
                           activate: { NSRunningApplication(processIdentifier: pid)?.activate() }))
    }
    return refs
}

/// Switch to a browser tab by title: raise its window, bring the app forward, press the tab.
/// Prefers an on-screen element (a hidden/collapsed mirror may not respond to the press).
private func activateAXTab(pid: pid_t, title: String) {
    let els = collectAXTabs(AXUIElementCreateApplication(pid))
    guard let e = els.first(where: { axTitle($0) == title && axOnScreen($0) })
              ?? els.first(where: { axTitle($0) == title }) else { return }
    if let w = axWindowOf(e) { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
    NSRunningApplication(processIdentifier: pid)?.activate()
    AXUIElementPerformAction(e, kAXPressAction as CFString)
}

/// Active (selected, on-screen) tab title — lets summon land on the current chart/page.
private func axBrowserActiveTitle(_ appName: String) -> String? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else { return nil }
    let els = collectAXTabs(AXUIElementCreateApplication(app.processIdentifier))
    return (els.first(where: { axSelected($0) && axOnScreen($0) }) ?? els.first(where: axSelected)).map(axTitle)
}

// MARK: - Public ops

func isRunning(_ name: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
}

/// Attributes each on-screen window to a macOS Space via the private CoreGraphics (SkyLight) Space
/// API — the only way to know which Space a window is on (the public AX API can't, and is flaky/opaque
/// for some apps like Messages and Java apps). Loaded with dlsym so a missing symbol on a future macOS
/// degrades gracefully (currentSpace() returns nil → callers fall back to no gating) instead of a
/// launch-time crash. Needs no permission — not even Accessibility.
private enum CGSpaces {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias ManagedFn  = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias ForWinsFn  = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle = dlopen(nil, RTLD_LAZY)   // symbols are already loaded in-process (CoreGraphics)
    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let mainConn = sym("CGSMainConnectionID", MainConnFn.self)
    private static let managed  = sym("CGSCopyManagedDisplaySpaces", ManagedFn.self)
    private static let forWins  = sym("CGSCopySpacesForWindows", ForWinsFn.self)

    /// (pids with a window on the current Space, pids with any on-screen window). nil if the private
    /// API is unavailable — callers then skip Space gating entirely.
    static func currentSpace() -> (onCurrent: Set<pid_t>, anyRealWindow: Set<pid_t>)? {
        guard let mainConn = mainConn, let managed = managed, let forWins = forWins else { return nil }
        let conn = mainConn()
        guard let displays = managed(conn)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        // "Current Space" is PER DISPLAY — with "Displays have separate Spaces" (or just multiple
        // monitors) there are several visible Spaces at once. Collect them ALL: an app is "here" if
        // it's on ANY visible Space. (The earlier single-value version kept only the last display's
        // current Space, so everything on the other display's Space was gated out permanently.)
        var current = Set<Int>()
        for d in displays { if let c = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int { current.insert(c) } }
        guard !current.isEmpty else { return nil }

        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var widsByPid: [pid_t: [Int]] = [:]
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {          // layer 0 = app windows (skip menubar/Dock chrome)
            guard let p = w[kCGWindowOwnerPID as String] as? Int, let wid = w[kCGWindowNumber as String] as? Int else { continue }
            widsByPid[pid_t(p), default: []].append(wid)
        }
        // Per pid, take the UNION of its windows' Spaces. Apps keep phantom off-Space helper windows
        // (full-width 30px strips, 0-size panels) even after every real window is closed — those carry
        // NO Space, so an app whose union is empty has no REAL window at all. That distinction powers
        // both the Space gate (fail-open) and the "no window" group (which must not be fooled by phantoms).
        var onCurrent = Set<pid_t>(), anyRealWindow = Set<pid_t>()
        for (pid, wids) in widsByPid {
            let sp = Set(forWins(conn, 0x7, wids as CFArray)?.takeRetainedValue() as? [Int] ?? [])   // 0x7 = all Space types
            guard !sp.isEmpty else { continue }                                  // only phantom/off-Space helpers → no real window
            anyRealWindow.insert(pid)
            if !sp.isDisjoint(with: current) { onCurrent.insert(pid) }           // has a window on a visible Space
        }
        return (onCurrent, anyRealWindow)
    }
}

func allContexts() -> [TabRef] {
    var refs = ADAPTERS.filter { isRunning($0.app) }.flatMap { $0.enumerate() }
    refs += genericContexts()
    refs += pluginContexts()                         // external drop-in adapters (out-of-process)

    // Space-awareness, made CONSISTENT. The generic AX path only ever sees windows on the current
    // Space, but adapters/plugins enumerate via AppleScript / IPC, which see every Space — so without
    // this an app parked on another Space (Messages, VS Code, TradingView) leaks its tabs here while
    // generic apps don't. Gate every source by "does this app have a window on THIS Space", attributed
    // via CGS. FAILS OPEN: if the Space API is unavailable, or an app has no attributable window at
    // all (e.g. Messages with its window closed), we don't gate it — we never hide what we can't place.
    guard let space = CGSpaces.currentSpace() else { return refs }   // no Space API → show everything
    var shown: [pid_t: Bool] = [:]
    func onSpace(_ appName: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName })
        else { return true }                                          // not a real running app (always-on plugin) → keep
        let pid = app.processIdentifier
        if let v = shown[pid] { return v }
        let v = !space.anyRealWindow.contains(pid)  // no real window anywhere → can't place it → fail open
             || space.onCurrent.contains(pid)       // has a window on this Space → show
        shown[pid] = v; return v
    }
    return refs.filter { onSpace($0.app) }
}

/// Bridge external plugins into the same TabRef list the built-in adapters produce. Each plugin
/// item's `activate` shells back to `<exec> activate <id>` (longer timeout — activation may switch
/// apps). Purely additive: with no plugins installed this returns [].
func pluginContexts() -> [TabRef] {
    PluginHost.listAll(isRunning: isRunning).flatMap { plugin, items in
        items.map { it in
            // Use the REAL app name (targetApp) so tabs match the frontmost app for landing and
            // resolve the app's icon; fall back to the plugin's display name if no targetApp.
            TabRef(app: plugin.manifest.targetApp ?? plugin.manifest.name,
                   group: it.group ?? plugin.manifest.targetApp ?? plugin.manifest.name,
                   title: it.title,
                   url: it.url,
                   subtitle: it.subtitle?.isEmpty == false ? it.subtitle : nil,   // e.g. VS Code's folder
                   isActive: it.active ?? false,                                  // e.g. VS Code's currently-open file
                   close: (plugin.manifest.supportsClose == true)                 // hover-× only for plugins that handle `close`
                       ? { _ = PluginHost.run(plugin, ["close", it.id], timeout: 2.0) } : nil,
                   activate: { _ = PluginHost.run(plugin, ["activate", it.id], timeout: 2.0) })
        }
    }
}

func activateAndSelect(_ ref: TabRef) { ref.activate() }

/// The currently-active tab title for an app (for the per-app row subtitle).
func activeTitle(_ app: String) -> String? {
    switch app {
    case "Arc":           let w = arcRegularWindow(); return w > 0 ? osaString("tell application \"Arc\" to get title of active tab of window \(w)") : nil
    case "Google Chrome": return osaString("tell application \"Google Chrome\" to get title of active tab of front window")
    case "Safari":        return osaString("tell application \"Safari\" to get name of current tab of front window")
    case "iTerm2":        return osaString("tell application \"iTerm2\" to get name of current session of current tab of current window")
    case let x where AX_BROWSERS.contains(x): return axBrowserActiveTitle(x)
    default:              return nil   // generic (and plugin-backed apps): caller falls back to first window title
    }
}

/// The title of Arc's currently active Space (from a regular window), or nil.
func arcActiveSpace() -> String? {
    let w = arcRegularWindow(); guard w > 0 else { return nil }
    return osaString("tell application \"Arc\" to get title of active space of window \(w)")
}

/// All Arc Space names in sidebar order — INCLUDING spaces with no open tabs
/// (those produce no TabRef, so the rail must get the list from here, not the tabs).
func arcSpaceList() -> [String] {
    let w = arcRegularWindow(); guard w > 0 else { return [] }
    return osaList("tell application \"Arc\" to get name of spaces of window \(w)")
}

/// Public Space→emoji map (resolved via Arc's own bundled tables).
func arcSpaceEmojiMap() -> [String: String] { arcSpaceEmojis() }

/// Bring an app to the front (its current tab/window).
func activateApp(_ name: String) {
    NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.activate()
}

/// Regular apps that are running but have NO real window on ANY Space — they show in ⌘-Tab yet have
/// nothing for Jay to summon. Surfaced in a collapsed "no window" group (⏎ brings the app forward).
/// `shown` = apps already listed with tabs/windows, so we never double-list. "Real window" = a
/// Space-attributed one: apps keep phantom off-Space helper windows (30px strips, 0-size panels) even
/// after every real window is closed, so counting raw CGWindowList entries would wrongly treat a
/// windowless app (e.g. Obsidian with its window closed) as windowed. This is TRUE windowless, NOT
/// "on another Space": an app parked on / minimized to another Space still has a real window, so it's
/// excluded here and simply doesn't appear — same as a generic app on another Space.
func windowlessApps(excluding shown: Set<String>) -> [String] {
    guard let real = CGSpaces.currentSpace()?.anyRealWindow else { return [] }   // no Space API → can't tell reliably → no group
    var out: [String] = []
    for running in NSWorkspace.shared.runningApplications {
        guard running.activationPolicy == .regular,                          // real UI apps only (skips accessories + us)
              let name = running.localizedName,
              name != "Jay", !shown.contains(name) else { continue }
        if !real.contains(running.processIdentifier) { out.append(name) }    // no real window anywhere → truly windowless
    }
    return out.sorted()
}
