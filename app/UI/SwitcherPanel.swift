import AppKit
import CoreImage

// Per-context glyph color. Each context can be tinted individually (right-click ▸ Color);
// defaults to the warm amber (the Claude UI hue). Stored as a [contextId: archived NSColor] map.
private let kContextColors = "contextColors"
func defaultContextAccent() -> NSColor { NSColor(srgbRed: 0.94, green: 0.71, blue: 0.33, alpha: 1) }

func contextColor(for id: String) -> NSColor {
    if let map = UserDefaults.standard.dictionary(forKey: kContextColors) as? [String: Data],
       let d = map[id],
       let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: d) { return c }
    return defaultContextAccent()
}

/// Set (or clear, with nil) one context's color.
func setContextColor(_ id: String, _ color: NSColor?) {
    var map = (UserDefaults.standard.dictionary(forKey: kContextColors) as? [String: Data]) ?? [:]
    if let color, let d = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
        map[id] = d
    } else {
        map.removeValue(forKey: id)
    }
    UserDefaults.standard.set(map, forKey: kContextColors)
}

// Curated swatches offered in the per-context Color menu (amber first = the default).
let contextColorPresets: [(name: String, color: NSColor)] = [
    ("Amber",   NSColor(srgbRed: 0.94, green: 0.71, blue: 0.33, alpha: 1)),
    ("Blue",    NSColor(srgbRed: 0.40, green: 0.62, blue: 0.95, alpha: 1)),
    ("Green",   NSColor(srgbRed: 0.42, green: 0.78, blue: 0.50, alpha: 1)),
    ("Teal",    NSColor(srgbRed: 0.36, green: 0.78, blue: 0.78, alpha: 1)),
    ("Purple",  NSColor(srgbRed: 0.70, green: 0.55, blue: 0.93, alpha: 1)),
    ("Pink",    NSColor(srgbRed: 0.94, green: 0.55, blue: 0.72, alpha: 1)),
    ("Graphite", NSColor(srgbRed: 0.62, green: 0.65, blue: 0.69, alpha: 1)),
]

/// Approximate sRGB equality (archived colors round-trip with tiny drift) for the menu checkmark.
func colorsClose(_ a: NSColor, _ b: NSColor) -> Bool {
    guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
    return abs(x.redComponent - y.redComponent) < 0.02
        && abs(x.greenComponent - y.greenComponent) < 0.02
        && abs(x.blueComponent - y.blueComponent) < 0.02
}

/// A small rounded color square for menu items.
func colorSwatch(_ color: NSColor, _ size: CGFloat = 12) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 3, yRadius: 3).fill()
    img.unlockFocus()
    return img
}

/// Transparent overlay that never intercepts the mouse — hosts the border-beam layer
/// above the vibrancy material (sublayers added to an NSVisualEffectView's own backing
/// layer don't reliably composite).
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Panel background that reports when the cursor enters/leaves the whole panel
/// (used to auto-dismiss an edge-summoned panel when the mouse moves away).
final class HoverEffectView: NSVisualEffectView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onEnter?() }
    override func mouseExited(with e: NSEvent) { onExit?() }
}

/// A Space-rail chip that highlights on hover (subtle rounded background + brighten).
final class RailChip: NSButton {
    var restingAlpha: CGFloat = 1
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.cornerRadius = 6                            // curved square, not a circle
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        animator().alphaValue = 1
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        animator().alphaValue = restingAlpha
    }
}

/// Table that moves the selection to the row under the cursor on hover, so mouse-over
/// shows the same highlight as keyboard navigation.
/// NSMenuItem that runs a closure (so menus can be built inline without target/action plumbing).
final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self; state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) not used") }
    @objc private func fire() { handler() }
}

final class HoverTable: NSTableView {
    var onHoverRow: ((Int) -> Void)?
    var onMenuForRow: ((Int) -> NSMenu?)?                 // right-click → per-row context menu
    var onSwipe: ((Int) -> Void)?                         // two-finger horizontal: +1 = back, -1 = drill in
    private var swipeDX: CGFloat = 0
    private var swipeFired = false

    override func menu(for event: NSEvent) -> NSMenu? {
        let r = row(at: convert(event.locationInWindow, from: nil))
        guard r >= 0 else { return nil }
        return onMenuForRow?(r)
    }

    /// Two-finger horizontal swipe drills the hierarchy (like →/←), once per gesture. Vertical
    /// scrolling still passes through to move the selection. Direction follows the system back/
    /// forward convention (same sign as the browser swipe), so it respects natural-scroll setting.
    override func scrollWheel(with e: NSEvent) {
        guard e.momentumPhase == [] else { super.scrollWheel(with: e); return }   // ignore the inertia tail
        if e.phase.contains(.began) { swipeDX = 0; swipeFired = false }
        if !swipeFired, e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) {
            swipeDX += e.scrollingDeltaX
            if abs(swipeDX) > 55 {                        // deliberate swipe, not a stray nudge
                swipeFired = true
                onSwipe?(swipeDX > 0 ? 1 : -1)           // right → back (←), left → drill in (→)
            }
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { swipeDX = 0; swipeFired = false }
        super.scrollWheel(with: e)                        // keep vertical scrolling working
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) {
        onHoverRow?(row(at: convert(e.locationInWindow, from: nil)))
    }
    // Allow an embedded text field (the context-name RenameField) to begin editing on a SINGLE
    // click. By default NSTableView blocks the field editor from taking focus until the row is
    // selected — but our header rows aren't selectable, so without this rename never starts.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCommandK: (() -> Void)?          // ⌘K → focus search
    var onCommandComma: (() -> Void)?      // ⌘, → preferences
    var onCommandQ: (() -> Void)?          // ⌘Q → quit the target app
    var onCancel: (() -> Void)?            // esc → dismiss (fires when no focused field handled it)

    // esc bubbles here when the search field isn't first responder; without this it'd be
    // unhandled (a beep) and the panel wouldn't close from e.g. the apps list.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // No menu bar (accessory app), so ⌘A/C/V/X/Z (and ⌘K/⌘,) have no menu item to fire.
    // Route the standard editing shortcuts to the first responder, and our own to closures.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (e.charactersIgnoringModifiers ?? "").lowercased()
        if flags == .command {
            if key == "k" { onCommandK?(); return true }
            if key == "," { onCommandComma?(); return true }
            if key == "q" { onCommandQ?(); return true }
            let map: [String: Selector] = [
                "a": #selector(NSResponder.selectAll(_:)),
                "c": #selector(NSText.copy(_:)),
                "v": #selector(NSText.paste(_:)),
                "x": #selector(NSText.cut(_:)),
                "z": NSSelectorFromString("undo:"),   // routed to the field editor's undo manager via the responder chain
            ]
            if let sel = map[key], NSApp.sendAction(sel, to: nil, from: self) { return true }
        } else if flags == [.command, .shift], key == "z" {
            if NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: e)
    }
}

// Fetches site favicons by domain. Tries multiple services in order (DuckDuckGo → Google) so a
// miss on one falls through to the next, and persists results to disk so they show instantly next
// launch and we don't re-hit the network (which is what causes the patchy throttled misses).
final class FaviconLoader {
    static let shared = FaviconLoader()
    private var cache: [String: NSImage] = [:]   // in-memory, main-thread; keyed by DOMAIN (app-agnostic → shared across all browsers)
    private var waiters: [String: [(NSImage) -> Void]] = [:]   // per-domain callbacks; ALL fire on arrival (not just the first requester)
    var onAnyLoad: (() -> Void)?                  // fired (main) after any icon arrives → coalesced UI refresh
    private let dir: URL = {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Jay/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func domain(of urlString: String?) -> String? {
        guard let s = urlString, let host = URL(string: s)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    // scheme://host[:port] of the actual page, so we can fetch its favicon directly.
    static func origin(of urlString: String?) -> String? {
        guard let s = urlString, let u = URL(string: s), let scheme = u.scheme, let host = u.host else { return nil }
        return u.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
    func cached(_ domain: String) -> NSImage? { cache[domain] }

    // Source order: the site itself first (works for private/tailnet hosts the way a browser does,
    // since we run on the user's machine), then the public proxies as fallback.
    private func sources(_ domain: String, _ pageURL: String?) -> [URL] {
        var urls: [URL] = []
        if let o = Self.origin(of: pageURL), let direct = URL(string: "\(o)/favicon.ico") { urls.append(direct) }
        urls += ["https://icons.duckduckgo.com/ip3/\(domain).ico",
                 "https://www.google.com/s2/favicons?domain=\(domain)&sz=64"].compactMap { URL(string: $0) }
        return urls
    }

    func load(_ domain: String, from pageURL: String?, _ done: @escaping (NSImage) -> Void) {
        if let img = cache[domain] { done(img); return }            // already known → instant
        waiters[domain, default: []].append(done)                   // queue THIS view's callback
        if waiters[domain]!.count > 1 { return }                    // a fetch for this domain is already running
        let file = dir.appendingPathComponent("\(domain).png")
        DispatchQueue.global(qos: .utility).async {
            if let data = try? Data(contentsOf: file), let img = NSImage(data: data), Self.usable(img) {
                self.deliver(domain, img); return                   // disk hit — no network
            }
            // Network lookups are opt-out (Preferences → Site icons). Off → make no network call;
            // clear this domain's waiters so a later re-enable can retry it.
            guard UserDefaults.standard.bool(forKey: "faviconLookup") else {
                DispatchQueue.main.async { self.waiters[domain] = nil }; return
            }
            self.fetch(domain, self.sources(domain, pageURL), 0, file)
        }
    }
    private func fetch(_ d: String, _ urls: [URL], _ i: Int, _ file: URL) {
        guard i < urls.count else { DispatchQueue.main.async { self.waiters[d] = nil }; return }  // all sources missed → allow retry later
        var req = URLRequest(url: urls[i]); req.timeoutInterval = 6   // dead/slow origin → fall through, don't stall
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data, let img = NSImage(data: data), Self.usable(img) {
                try? data.write(to: file)                          // persist for next launch
                self.deliver(d, img)
            } else {
                self.fetch(d, urls, i + 1, file)                   // try the next service
            }
        }.resume()
    }
    private func deliver(_ d: String, _ img: NSImage) {
        DispatchQueue.main.async {
            self.cache[d] = img
            let dones = self.waiters[d] ?? []; self.waiters[d] = nil
            for done in dones { done(img) }                        // update EVERY view that asked for this domain
            self.onAnyLoad?()
        }
    }
    private static func usable(_ img: NSImage) -> Bool { img.isValid && img.size.width >= 8 && img.size.height >= 8 }
}

final class PillRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 4, dy: 2)     // slightly wider pill → the "currently open" dot sits comfortably inside, not on the edge
        NSColor(white: 1, alpha: 0.10).setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
    }
}

private enum Row {
    case app(name: String, sub: String, count: Int)
    case back(String)
    case appHeader(String)                                    // identity header when drilled into an app: big icon + name
    case header(String, icon: String?, active: Bool)          // Space / group header (icon = emoji; active = current Arc space)
    case folderHeader(name: String, key: String, collapsed: Bool)  // Arc folder, collapsible
    case splitHeader(title: String, key: String, count: Int, collapsed: Bool)  // Arc split-view group
    case rule                                                 // thin separator (folders ↑ / loose tabs ↓)
    case newTab(String)                                       // "+ New tab" action row for a browser
    case tab(TabRef)
    case context(label: String, apps: [String], id: String, aiLabeled: Bool)  // aiLabeled = named on-device
    case contextHeader(id: String, label: String)            // editable identity header when drilled into a context
    case newContext                                          // "+ New context" entry (creates + enters pick-mode)
    case addTabs(String)                                     // "+ Add tabs" entry inside a context drill-in (enters pick-mode)
    case pickDone                                            // "‹ Done" — leave pick-mode
    case pickItem(TabRef, on: Bool)                          // a togglable item row in pick-mode (on = currently in the context)
}
private enum Mode: Equatable { case apps; case tabs(String); case context(String); case pick(String) }

/// App-row container with a clickable pin button that's hover-revealed: shown always
/// when pinned (filled), fades in on hover when unpinned (outline). Click toggles.
final class AppCell: NSView {
    let pin = NSButton()
    var pinned = false { didSet { applyPin(hovering: false) } }
    var onTogglePin: (() -> Void)?
    private var ta: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        pin.isBordered = false; pin.imagePosition = .imageOnly; pin.refusesFirstResponder = true
        pin.target = self; pin.action = #selector(toggle)
        addSubview(pin); applyPin(hovering: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func toggle() { onTogglePin?() }

    private func applyPin(hovering: Bool) {
        pin.isHidden = !hovering                          // pinned state is shown by the "PINNED" section, not a glyph
        pin.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "pin")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        pin.contentTintColor = pinned ? .secondaryLabelColor : .tertiaryLabelColor   // neutral, not amber
        pin.toolTip = pinned ? "Unpin" : "Pin"
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = ta { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); ta = t
    }
    override func mouseEntered(with e: NSEvent) { applyPin(hovering: true) }
    override func mouseExited(with e: NSEvent) { applyPin(hovering: false) }
}

/// Tab-row container with a hover-revealed close (×) button (Arc-style). Hidden until
/// the cursor is over the row; clicking it closes the tab without dismissing the panel.
/// A button whose glyph grows a little on hover (smooth, scaled from its center) so it reads as an
/// actionable target without a background or icon swap. Used for the tab close ×.
final class HoverGrowButton: NSButton {
    private var hoverTA: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTA { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); hoverTA = t
    }
    override func mouseEntered(with e: NSEvent) { scaleTo(1.3) }
    override func mouseExited(with e: NSEvent)  { scaleTo(1.0) }
    private func scaleTo(_ s: CGFloat) {
        wantsLayer = true
        guard let l = layer else { return }
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)               // scale from center, no position shift
        l.position = CGPoint(x: frame.midX, y: frame.midY)
        let from = l.presentation()?.transform ?? l.transform
        let to = CATransform3DMakeScale(s, s, 1)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = from; a.toValue = to
        a.duration = 0.12; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(a, forKey: "grow"); l.transform = to
    }
}

final class TabCell: NSView {
    let closeBtn = HoverGrowButton()                       // plain ×, shown on row hover; mildly grows on hover
    var onClose: (() -> Void)?
    private var ta: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeBtn.isBordered = false; closeBtn.imagePosition = .imageOnly; closeBtn.refusesFirstResponder = true
        closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "close")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.target = self; closeBtn.action = #selector(doClose)
        closeBtn.isHidden = true; closeBtn.toolTip = "Close tab"
        addSubview(closeBtn)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    @objc private func doClose() { onClose?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = ta { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); ta = t
    }
    override func mouseEntered(with e: NSEvent) { closeBtn.isHidden = false }
    override func mouseExited(with e: NSEvent) { closeBtn.isHidden = true }
}

/// Inline-editable context name. Reads as a plain label until clicked, then becomes an
/// editable field; ⏎ commits, Esc cancels. Self-delegating so it doesn't touch the panel's
/// search-field delegate.
final class RenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    private var original = ""

    init(string: String) {
        super.init(frame: .zero)
        original = string; stringValue = string
        isEditable = true; isSelectable = true; isBordered = false; drawsBackground = false
        focusRingType = .none; lineBreakMode = .byTruncatingTail
        wantsLayer = true; layer?.cornerRadius = 5
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // A direct click on the field starts editing even though we're inside an NSTableView.
    override func mouseDown(with event: NSEvent) {
        if window?.makeFirstResponder(self) == true { currentEditor()?.selectAll(nil) }
        else { super.mouseDown(with: event) }
    }
    // Show a subtle filled pill while editing so it's obvious the name is now editable.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { drawsBackground = true; backgroundColor = NSColor.white.withAlphaComponent(0.10) }
        return ok
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        drawsBackground = false
        let v = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { stringValue = original; return }     // empty → keep current name
        if v != original { original = v; onCommit?(v) }
    }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) {          // Esc → revert, drop focus
            stringValue = original; window?.makeFirstResponder(nil); return true
        }
        return false
    }
}

final class SwitcherPanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate {

    private let panel: KeyablePanel
    private let vibrant = HoverEffectView()
    private var beamLayers: [CAShapeLayer] = []      // comet: stacked overlapping segments → smooth gradient
    private let beamCount = 28                        // many thin steps → granular, no visible banding
    private let beamSeg: CGFloat = 8                  // step between segments (total beam ≈ count × seg)
    private let beamView = PassthroughView()         // overlay that hosts the beam above the material
    private var beamPulseTimer: Timer?               // re-sweeps once every 30s while the panel stays open
    private var beamGen = 0                           // pulse generation; stale completions must not hide a fresh sweep
    private let search = NSSearchField()
    private let table = HoverTable()
    private let scroll = NSScrollView()
    private let gear = NSButton()
    private let searchLogo = NSImageView()                   // faint jay at the search field's right edge (hidden while typing) — mirrors the website
    private let footer = NSTextField(labelWithString: "")   // faint key-hint row at the very bottom
    private let footerH: CGFloat = 16
    private var navIcon: NSImage?                            // 4-way "move" glyph for the navigate hint
    private let emptyLabel = NSTextField(labelWithString: "") // centered message when the list is empty
    private let spaceRail = NSView()         // Arc: horizontal Space switcher (bottom strip)
    private let spaceTitle = NSTextField(labelWithString: "")   // active Space name (subtitle under "Arc")
    private let spaceBack = NSButton()                          // ‹ back to app list (top band)
    private let spaceSep = NSView()                             // rule under the Space name
    private let identSep = NSView()                             // rule under the Arc identity block
    private let arcIcon = NSImageView()                        // big Arc icon (identity, matches generic app header)
    private let arcName = NSTextField(labelWithString: "Arc")   // "Arc" name beside the icon
    private let railH: CGFloat = 36
    private let spaceTitleH: CGFloat = 22      // prominent Space-name line ([emoji] name)
    private let spaceBackH: CGFloat = 16       // "‹ Apps" line above the identity
    private let arcIdentH: CGFloat = 36        // big Arc icon + "Arc" name
    var onOpenSettings: (() -> Void)?

    private var all: [TabRef] = []
    private var activeArcSpace: String?      // title of Arc's current Space (default selection)
    private var selectedSpace: String?       // Space being viewed in the rail; nil = use active/default
    private var arcSpacesCache: [String] = []        // ALL Arc spaces (incl. empty), sidebar order
    private var arcEmojiCache: [String: String] = [:] // Space → emoji
    private var appOrder: [String] = []
    private var rows: [Row] = []
    private var drilledActiveTitle: String?          // title of the drilled app's active tab (browsers/iTerm) → marks the "currently open" dot
    private var activeRowIndex: Int?                 // the single row that gets the dot (first match — avoids N dots for same-titled tabs)
    private var mode: Mode = .apps
    private(set) var visible = false
    private var preferredScreen: NSScreen?           // edge-trigger: show on the screen you pressed
    private var anchorRight = false                  // mirror to the right edge (a monitor whose left is internal)
    private var menuOpen = false                     // a right-click menu is up → don't auto-close the panel
    private var edgeAutoClose = false                // opened via edge → dismiss when cursor leaves the panel
    private var edgeHoverPoll: Timer?                // polls cursor-vs-panel-frame (no tracking-area / band quirks)
    private var outsideSince: CFTimeInterval = 0     // when the cursor first left the panel rect (0 = inside)
    private var lastFrontApp: String?                // last NON-self frontmost app, for re-summon targeting
    private lazy var appMRU: [String] =              // app names, most-recently-used first (persisted)
        UserDefaults.standard.stringArray(forKey: "appMRU") ?? []
    private lazy var appPins: [String] =             // pinned app names, fixed atop the list (persisted)
        UserDefaults.standard.stringArray(forKey: "appPins") ?? []
    private var store: ContextStore!                  // cross-app context inference (top "Contexts" section)
    private var showContexts: Bool { UserDefaults.standard.bool(forKey: "showContexts") }
    private var clickAway: Any?
    private var appSwitchObs: Any?       // hide when you ⌘Tab to another app
    private var summonSource = "keyboard"            // usage log: which trigger summoned us
    private var didPick = false                      // usage log: did this summon end in a pick?

    // Folders default OPEN; we persist only the CLOSED ones (key = group + folder name).
    private static let collapseKey = "collapsedArcFolders"
    private var collapsedFolders: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: SwitcherPanel.collapseKey) ?? [])
    private func folderKey(_ group: String, _ folder: String) -> String { group + "\u{1}" + folder }

    // Splits collapse the same way (keyed by Arc split id), persisted separately.
    private static let splitCollapseKey = "collapsedArcSplits"
    private var collapsedSplits: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: SwitcherPanel.splitCollapseKey) ?? [])
    private func toggleSplit(_ key: String) {
        if collapsedSplits.contains(key) { collapsedSplits.remove(key) } else { collapsedSplits.insert(key) }
        UserDefaults.standard.set(Array(collapsedSplits), forKey: SwitcherPanel.splitCollapseKey)
    }

    // Arc Space rail helpers.
    private func spaceName(of group: String) -> String { group.components(separatedBy: " · ").last ?? group }
    /// All Arc spaces incl. empty ones (from the live list); falls back to tab-derived.
    private func arcSpaces() -> [String] {
        if !arcSpacesCache.isEmpty { return arcSpacesCache }
        var seen = Set<String>(); var out: [String] = []
        for r in all where r.app == "Arc" {
            let n = spaceName(of: r.group)
            if !seen.contains(n) { seen.insert(n); out.append(n) }
        }
        return out
    }
    /// The Space currently shown: explicit selection, else the active Space, else the first.
    private func effectiveArcSpace() -> String? {
        let spaces = arcSpaces()
        if let s = selectedSpace, spaces.contains(s) { return s }
        if let a = activeArcSpace, spaces.contains(a) { return a }
        return spaces.first
    }
    private var arcRailActive: Bool {
        if case .tabs(let a) = mode, a == "Arc", !arcSpaces().isEmpty { return true }
        return false
    }
    private func arcSpaceEmoji(_ space: String) -> String? {
        arcEmojiCache[space] ?? all.first { $0.app == "Arc" && spaceName(of: $0.group) == space }?.groupIcon
    }
    /// Render an emoji to an image; desaturate to monochrome when not selected.
    private func emojiImage(_ s: String, grayscale: Bool) -> NSImage {
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 10)])
        let sz = attr.size()
        let base = NSImage(size: NSSize(width: ceil(sz.width), height: ceil(sz.height)))
        base.lockFocus(); attr.draw(at: .zero); base.unlockFocus()
        guard grayscale, let tiff = base.tiffRepresentation, let ci = CIImage(data: tiff),
              let f = CIFilter(name: "CIColorControls",
                               parameters: [kCIInputImageKey: ci, kCIInputSaturationKey: 0.0]),
              let out = f.outputImage else { return base }
        let rep = NSCIImageRep(ciImage: out)
        let g = NSImage(size: base.size); g.addRepresentation(rep)   // same POINT size as the color one
        return g
    }

    /// Bottom Space switcher: emoji chips — monochrome when inactive, full color when
    /// selected (no pill). The active Space's name lives at the top, Arc-style.
    private func buildSpaceRail() {
        spaceRail.subviews.forEach { $0.removeFromSuperview() }
        let spaces = arcSpaces(); let sel = effectiveArcSpace()
        let d: CGFloat = 24, gap: CGFloat = 10             // chip hit/hover box (emoji ~14 inside)
        let cy = (spaceRail.bounds.height - d) / 2
        let totalW = CGFloat(spaces.count) * d + CGFloat(max(0, spaces.count - 1)) * gap
        var x = max(14, (spaceRail.bounds.width - totalW) / 2)   // centered → no right-side gap
        for (i, sp) in spaces.enumerated() {
            let isSel = sp == sel
            let btn = RailChip(); btn.isBordered = false; btn.bezelStyle = .inline
            btn.title = ""; btn.tag = i; btn.target = self; btn.action = #selector(railClicked(_:))
            btn.image = emojiImage(arcSpaceEmoji(sp) ?? "•", grayscale: !isSel)
            btn.imageScaling = .scaleProportionallyDown
            btn.restingAlpha = isSel ? 1 : 0.7; btn.alphaValue = btn.restingAlpha
            btn.frame = NSRect(x: x, y: cy, width: d, height: d)
            spaceRail.addSubview(btn)
            x += d + gap
        }
    }
    private func updateSpaceTitle() {
        let sp = effectiveArcSpace() ?? ""
        let emoji = arcSpaceEmoji(sp).map { "\($0)  " } ?? ""
        spaceTitle.stringValue = emoji + sp
    }
    @objc private func backToApps() { goBack() }

    @objc private func railClicked(_ sender: NSButton) {
        let spaces = arcSpaces()
        guard sender.tag < spaces.count else { return }
        selectedSpace = spaces[sender.tag]
        refresh()                                             // re-filter content + rebuild rail highlight
    }

    /// The rows for one Arc Space (folder headers + tabs, honoring collapse). Shared by
    /// rendering and by the height measurement that keeps the panel from resizing on switch.
    private func arcRows(for space: String?) -> [Row] {
        let mine = all.filter { $0.app == "Arc" && spaceName(of: $0.group) == space }
        var splitCount: [String: Int] = [:]                       // members per split (this Space)
        for it in mine { if let s = it.splitId { splitCount[s, default: 0] += 1 } }

        var out: [Row] = []
        var lastFolder: String? = nil, lastSplit: String? = nil
        var hadFolder = false, ruleAdded = false
        for it in mine {
            if let f = it.folder {                                // — folders first —
                hadFolder = true
                if f != lastFolder {
                    let key = folderKey(it.group, f)
                    out.append(.folderHeader(name: f, key: key, collapsed: collapsedFolders.contains(key)))
                    lastFolder = f; lastSplit = nil
                }
                if collapsedFolders.contains(folderKey(it.group, f)) { continue }
            } else {                                              // — loose tabs, below a rule —
                if hadFolder && !ruleAdded { out.append(.rule); ruleAdded = true }
                lastFolder = nil
            }
            // split sub-group header (whenever the split changes)
            if it.splitId != lastSplit {
                lastSplit = it.splitId
                if let sid = it.splitId {
                    let named = (it.splitTitle?.isEmpty == false)
                    out.append(.splitHeader(title: named ? it.splitTitle! : "", key: sid,
                                            count: splitCount[sid] ?? 0, collapsed: collapsedSplits.contains(sid)))
                }
            }
            if let sid = it.splitId, collapsedSplits.contains(sid) { continue }   // hide collapsed split members
            out.append(.tab(it))
        }
        return out
    }

    /// Tallest Space's rendered height (incl. the back row), so switching Spaces in the
    /// rail never resizes the panel — shorter Spaces just leave space below.
    private func arcRailInnerHeight() -> CGFloat {
        var maxH: CGFloat = 0
        for space in arcSpaces() {
            let r: [Row] = arcRows(for: space)
            let h = r.reduce(0) { $0 + height($1) } + table.intercellSpacing.height * CGFloat(r.count)
            maxH = max(maxH, h)
        }
        return maxH
    }
    private func toggleFolder(_ key: String) {
        if collapsedFolders.contains(key) { collapsedFolders.remove(key) } else { collapsedFolders.insert(key) }
        UserDefaults.standard.set(Array(collapsedFolders), forKey: SwitcherPanel.collapseKey)
    }
    private var iconCache: [String: NSImage] = [:]

    private let searchH: CGFloat = 40
    private let minW: CGFloat = 234, maxW: CGFloat = 560
    private lazy var W: CGFloat = {                         // user-resizable width (persisted, clamped)
        let saved = UserDefaults.standard.double(forKey: "panelWidth")
        return saved > 0 ? min(max(saved, minW), maxW) : 320
    }()
    private let appRowH: CGFloat = 54, tabRowH: CGFloat = 40, headerH: CGFloat = 24, backH: CGFloat = 26
    private let appHeaderH: CGFloat = 42
    private let folderHeaderH: CGFloat = 32

    override init() {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
                             backing: .buffered, defer: false)
        super.init()
        // No window shadow: the borderless window's layer is rectangular, so macOS draws a
        // rectangular shadow whose square corners poke out past our maskImage-rounded material.
        // Dropping it keeps the rounded corners clean (the panel sits flush to the screen edge anyway).
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self                              // for width-only resize constraints
        panel.onCommandK = { [weak self] in self?.focusSearch() }
        panel.onCommandComma = { [weak self] in self?.openSettings() }
        panel.onCommandQ = { [weak self] in self?.quitTarget() }
        panel.onCancel = { [weak self] in self?.onEscape() }
        // Edge-summon auto-close is handled by a cursor-vs-panel poll (startEdgeHoverWatch), not the
        // panel's mouseEntered/Exited — those misfire when the band pops the panel away from the cursor.

        // Contexts: inferred on summon only (store.ingest in show) — no background scanning during
        // normal use. gatherItems is the fallback scan path; the panel feeds its live scan instead.
        store = ContextStore(gatherItems: { allContexts() },
                             overrides: ContextOverrides(defaults: .standard),
                             labeler: makeContextLabeler())
        store.onChange = { [weak self] in self?.contextsDidChange() }
        FaviconLoader.shared.onAnyLoad = { [weak self] in self?.scheduleIconRefresh() }

        // Remember the real app you were in — when WE activate on summon, we mustn't
        // treat ourselves as the "current app" on the next summon.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastFrontApp = app.localizedName
            if let n = app.localizedName { self?.recordAppUse(n) }
            // Contexts are computed on summon (store.ingest in show), NOT on every app switch —
            // no background AppleScript scanning during normal use. Sticky cached labels keep
            // summon instant. (Tracking whether this cadence feels right: see follow-up ticket.)
        }

        vibrant.material = .sidebar; vibrant.blendingMode = .behindWindow; vibrant.state = .active
        // Round the RIGHT corners via maskImage (Apple's path for vibrancy) — clips the material
        // cleanly through the blur pipeline, with none of the light fringe a layer cornerRadius mask
        // leaves. Left stays square/flush to the screen edge. Stretchable, so it survives resize.
        vibrant.maskImage = Self.rightRoundedMask(radius: 22)
        vibrant.autoresizingMask = [.width, .height]
        panel.contentView = vibrant

        beamView.wantsLayer = true
        beamView.autoresizingMask = [.width, .height]
        for i in 0..<beamCount {
            let t = CGFloat(i) / CGFloat(beamCount - 1)             // 0…1 across the comet
            let a = sin(.pi * t)                                     // symmetric bell: fades in AND out, no hard start
            let seg = CAShapeLayer()
            seg.fillColor = NSColor.clear.cgColor
            seg.strokeColor = NSColor(srgbRed: 0.99, green: 0.80, blue: 0.40, alpha: a).cgColor
            seg.lineWidth = 1.75; seg.lineCap = .round
            seg.shadowColor = NSColor(srgbRed: 0.99, green: 0.80, blue: 0.40, alpha: 1).cgColor
            seg.shadowOpacity = Float(a); seg.shadowRadius = 6; seg.shadowOffset = .zero   // glow tracks brightness
            beamView.layer?.addSublayer(seg)
            beamLayers.append(seg)
        }

        search.placeholderString = "Search"
        search.font = .systemFont(ofSize: 14); search.focusRingType = .none; search.delegate = self
        vibrant.addSubview(search)

        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Preferences")
        gear.imageScaling = .scaleProportionallyDown
        gear.isBordered = false; gear.bezelStyle = .regularSquare
        gear.contentTintColor = .tertiaryLabelColor
        gear.target = self; gear.action = #selector(openSettings)
        gear.toolTip = "Preferences"
        vibrant.addSubview(gear)

        // faint jay logo at the search field's right edge (matches the website); hidden once you start typing
        if let p = Bundle.main.path(forResource: "menubar-glyph", ofType: "png"), let g = NSImage(contentsOfFile: p) {
            g.isTemplate = true; searchLogo.image = g
        }
        searchLogo.imageScaling = .scaleProportionallyDown
        searchLogo.contentTintColor = .tertiaryLabelColor
        vibrant.addSubview(searchLogo)

        footer.font = .systemFont(ofSize: 10.5); footer.textColor = .tertiaryLabelColor
        footer.alignment = .center                  // text set per-state in layout()
        let navCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
        navIcon = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                          accessibilityDescription: "navigate")?.withSymbolConfiguration(navCfg)
        vibrant.addSubview(footer)

        let col = NSTableColumn(identifier: .init("c")); col.width = W - 16
        table.addTableColumn(col); table.headerView = nil; table.backgroundColor = .clear
        table.style = .plain; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self; table.delegate = self; table.target = self
        table.action = #selector(rowClicked)
        table.onMenuForRow = { [weak self] r in self?.rowMenu(r) }   // right-click context menu
        table.onSwipe = { [weak self] dir in dir > 0 ? self?.goBack() : self?.drillIn() }  // swipe ↔ drill
        table.onHoverRow = { [weak self] r in           // mouse-over selects the row (same highlight as ↑↓)
            guard let self = self, r >= 0, r < self.rows.count, self.selectable(self.rows[r]),
                  self.table.selectedRow != r else { return }
            self.selectRow(r)
        }
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true; scroll.documentView = table
        vibrant.addSubview(scroll)
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center; emptyLabel.isHidden = true
        vibrant.addSubview(emptyLabel)
        vibrant.addSubview(spaceRail)
        spaceTitle.font = .systemFont(ofSize: 13, weight: .semibold); spaceTitle.textColor = .labelColor
        spaceTitle.lineBreakMode = .byTruncatingTail
        vibrant.addSubview(spaceTitle)
        arcIcon.imageScaling = .scaleProportionallyUpOrDown
        vibrant.addSubview(arcIcon)
        arcName.font = .systemFont(ofSize: 15, weight: .semibold); arcName.textColor = .labelColor
        vibrant.addSubview(arcName)
        for sep in [spaceSep, identSep] {
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            vibrant.addSubview(sep)
        }
        spaceBack.isBordered = false; spaceBack.bezelStyle = .inline
        spaceBack.target = self; spaceBack.action = #selector(backToApps)
        spaceBack.toolTip = "Back to apps"
        vibrant.addSubview(spaceBack)
        beamView.frame = vibrant.bounds
        vibrant.addSubview(beamView)                  // topmost: beam draws over all content
    }

    // MARK: rows

    /// Subsequence fuzzy match. Returns nil if `q`'s chars don't all appear in order in `text`;
    /// otherwise a score favouring contiguous runs, word-start hits, and an exact-substring bonus.
    static func fuzzyScore(_ q: String, _ text: String) -> Int? {
        let qLower = q.lowercased(), tLower = text.lowercased()
        let ql = Array(qLower), tl = Array(tLower)
        guard !ql.isEmpty else { return 0 }
        guard ql.count <= tl.count else { return nil }
        var qi = 0, score = 0, last = -2
        let seps: Set<Character> = [" ", "/", "-", "_", ".", ":", "·"]
        for (i, ch) in tl.enumerated() where qi < ql.count && ch == ql[qi] {
            var s = 1
            if i == last + 1 { s += 5 }                              // consecutive run
            if i == 0 || seps.contains(tl[i - 1]) { s += 4 }         // start of a word
            score += s; last = i; qi += 1
        }
        guard qi == ql.count else { return nil }                    // every query char matched, in order
        if tLower.contains(qLower) { score += 15 }                  // contiguous substring → strong bonus
        return score
    }

    // The app list (Pinned section, then the rest), used directly by default and inside the
    // "All Apps" accordion in contexts-first mode.
    private func appendAppRows() {
        func appRow(_ app: String) -> Row {
            let items = all.filter { $0.app == app }
            // Current tab: the app's own active tab (browsers/terminals via AppleScript), else a plugin's
            // active item (VS Code's open file), else the first tab.
            let current = activeTitle(app) ?? items.first(where: { $0.isActive })?.title ?? items.first?.title ?? ""
            return .app(name: app, sub: current, count: items.count)
        }
        let pinned = appOrder.filter { appPins.contains($0) }
        let rest = appOrder.filter { !appPins.contains($0) }
        if !pinned.isEmpty {
            rows.append(.header("Pinned", icon: nil, active: false))
            pinned.forEach { rows.append(appRow($0)) }
            rows.append(.rule)
        }
        rest.forEach { rows.append(appRow($0)) }
    }

    private func buildRows() {
        let q = search.stringValue.lowercased()
        rows.removeAll()
        drilledActiveTitle = nil
        if !q.isEmpty {                                  // search dives into tabs across all apps
            // Drilled into an app → its OWN matches lead, then others. From the apps list there's no
            // current app, so it's the plain global closest-match ranking.
            let curApp: String? = { if case .tabs(let a) = mode { return a }; return nil }()
            // matching contexts ride at the very top (ranked by match quality)
            if showContexts {
                let hits = orderedContexts()
                    .compactMap { c -> (WorkContext, Int)? in Self.fuzzyScore(q, c.label).map { (c, $0) } }
                    .sorted { $0.1 > $1.1 }
                for (c, _) in hits { rows.append(contextRow(c)) }
            }
            let mru = Dictionary(appMRU.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            var scored: [(Row, Int)] = []
            // matching APPS — so "google" surfaces the Google Chrome app itself, not only its tabs.
            // Skip the app you're already inside.
            for name in appOrder where name != curApp {
                guard let s = Self.fuzzyScore(q, name) else { continue }
                let items = all.filter { $0.app == name }
                scored.append((.app(name: name, sub: activeTitle(name) ?? items.first(where: { $0.isActive })?.title ?? items.first?.title ?? "", count: items.count),
                               s * 100 - (mru[name] ?? 99)))
            }
            // matching TABS — fuzzy across title + app + URL host (host was missing before, so
            // "google"/"arxiv" never matched a title-less tab). Tabs of the app you're inside get a
            // big boost so they lead; everything else follows by match quality.
            for it in all {
                let t = Self.fuzzyScore(q, it.title), a = Self.fuzzyScore(q, it.app)
                let u = it.url.flatMap { URL(string: $0)?.host ?? $0 }.flatMap { Self.fuzzyScore(q, $0) }
                guard let best = [t.map { $0 + 2 }, a, u].compactMap({ $0 }).max() else { continue }
                let scope = (it.app == curApp) ? 1_000_000 : 0
                scored.append((.tab(it), scope + best * 100 - (mru[it.app] ?? 99)))
            }
            scored.sort { $0.1 > $1.1 }
            for (row, _) in scored { rows.append(row) }
            return
        }
        switch mode {
        case .apps:
            // CONTEXTS — cross-app working sets the engine inferred. Top section, opt-out via prefs.
            if showContexts {
                let ctx = orderedContexts()
                if !ctx.isEmpty || !all.isEmpty {
                    rows.append(.header("Contexts", icon: nil, active: false))
                    for c in ctx { rows.append(contextRow(c)) }
                    rows.append(.newContext)               // "+ New context" → build one by hand
                    rows.append(.rule)
                }
            }
            appendAppRows()
        case .tabs(let app):
            let items = all.filter { $0.app == app }
            // Only pay for the live active-tab AppleScript when the adapter didn't already mark one (iTerm/plugins do).
            drilledActiveTitle = items.contains(where: { $0.isActive }) ? nil : activeTitle(app)

            if arcRailActive {
                // Arc: Space name + back live in the top band; show only this Space's folders + tabs.
                if isBrowser(app) { rows.append(.newTab(app)) }
                rows += arcRows(for: effectiveArcSpace())
                break
            }
            // "‹ Apps" escape hatch, then an identity header (big icon + name) + a rule —
            // mirrors the Arc Spaces layout so app-mode and Arc-mode read consistently.
            rows.append(.back(app))
            rows.append(.appHeader(app))
            rows.append(.rule)
            if isBrowser(app) { rows.append(.newTab(app)) }   // visible "+ New tab" (⌘-click = private)

            // Non-Arc (e.g. Chrome windows): inline group headers as before.
            let multi = Set(items.map { $0.group }).count > 1
            var lastGroup: String? = nil
            var lastFolder: String? = nil
            for it in items {
                if multi, it.group != lastGroup {
                    rows.append(.header(it.group, icon: it.groupIcon, active: false))
                    lastGroup = it.group; lastFolder = nil
                }
                if it.folder != lastFolder {
                    if let f = it.folder {
                        let key = folderKey(it.group, f)
                        rows.append(.folderHeader(name: f, key: key, collapsed: collapsedFolders.contains(key)))
                    }
                    lastFolder = it.folder
                }
                if let f = it.folder, collapsedFolders.contains(folderKey(it.group, f)) { continue }
                rows.append(.tab(it))
            }
        case .context(let id):
            // Drill-in: back hatch, editable identity header, then the context's items grouped by app.
            let ctx = store?.contexts.first { $0.id == id }
            rows.append(.back(""))                              // "‹ Apps"
            rows.append(.contextHeader(id: id, label: contextLabel(id)))
            rows.append(.rule)
            rows.append(.addTabs(id))                           // "+ Add tabs" → pick-mode for this context
            // App header + a FLAT list of its items (no Arc folder/split tree nesting — see the
            // flattened indent in the .tab renderer for .context mode). Map refs back to live TabRefs.
            let memberKeys = Set((ctx?.members ?? []).map { "\($0.app)\u{1}\($0.title)" })
            for app in ctx?.apps ?? [] {
                rows.append(.header(app, icon: nil, active: false))
                for it in all where it.app == app && memberKeys.contains("\(it.app)\u{1}\(it.title)") {
                    rows.append(.tab(it))
                }
            }
        case .pick(let id):
            // Build/edit a context: editable name + every open item with a toggle (✓ = in the context).
            rows.append(.pickDone)
            rows.append(.contextHeader(id: id, label: contextLabel(id)))
            rows.append(.rule)
            var lastApp: String? = nil
            for app in appOrder {
                for it in all where it.app == app {
                    if it.app != lastApp { rows.append(.header(it.app, icon: nil, active: false)); lastApp = it.app }
                    rows.append(.pickItem(it, on: store.isMember(it, of: id)))
                }
            }
        }
        // Exactly ONE "currently open" dot: the first row matching the active tab (title match can hit
        // several same-named tabs — this picks one instead of dotting them all).
        activeRowIndex = rows.firstIndex { if case .tab(let ref) = $0 {
            return ref.isActive || (drilledActiveTitle.map { !$0.isEmpty && ref.title == $0 } ?? false)
        }; return false }
    }

    // Current display label for a context id (user rename > AI > derived), valid even when the
    // context has no members yet (freshly created in pick-mode).
    private func contextLabel(_ id: String) -> String {
        store?.displayName(forGroup: id) ?? ContextKey.displayLabel(id)
    }

    private func height(_ r: Row) -> CGFloat {
        switch r {
        case .app: return appRowH; case .back: return backH; case .appHeader: return appHeaderH
        case .header: return headerH; case .folderHeader: return folderHeaderH
        case .splitHeader: return 22; case .rule: return 13; case .tab: return tabRowH
        case .newTab: return tabRowH
        case .context: return appRowH; case .contextHeader: return appHeaderH
        case .newContext, .addTabs, .pickItem: return tabRowH
        case .pickDone: return backH
        }
    }
    private func selectable(_ r: Row) -> Bool {
        switch r {
        case .app, .tab, .newTab, .context, .newContext, .addTabs, .pickDone, .pickItem, .appHeader: return true
        default: return false
        }
    }

    // MARK: layout / dynamic size

    private func layout() {
        let b = vibrant.bounds
        table.tableColumns.first?.width = b.width - 16     // track the (resizable) width
        search.frame = NSRect(x: 14, y: b.height - searchH - 10, width: b.width - 28 - 24, height: searchH)
        searchLogo.frame = NSRect(x: search.frame.maxX - 26, y: search.frame.midY - 7.5, width: 15, height: 15)
        searchLogo.isHidden = !search.stringValue.isEmpty     // give way to the native cancel button while typing
        gear.frame = NSRect(x: b.width - 30, y: b.height - searchH + 2, width: 20, height: 20)
        footer.frame = NSRect(x: 8, y: 2, width: b.width - 16, height: footerH)   // pinned near the bottom
        let floor = footerH + 16                           // breathing room above the footer
        // consistent across views; esc clears a query first, else closes (back is the "‹ Apps" button / ←).
        let escHint = search.stringValue.isEmpty ? "esc close" : "esc clear"
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: para]
        let s = NSMutableAttributedString()
        if let ic = navIcon {                        // 4-way move glyph stands in for ↑↓←→
            let att = NSTextAttachment(); att.image = ic
            att.bounds = CGRect(x: 0, y: -1.5, width: 13, height: 11)
            s.append(NSAttributedString(attachment: att))
        }
        s.append(NSAttributedString(string: " navigate   ·   ⏎ switch   ·   \(escHint)", attributes: attrs))
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        footer.attributedStringValue = s
        if arcRailActive {
            spaceRail.isHidden = false; spaceTitle.isHidden = false
            spaceBack.isHidden = false; spaceSep.isHidden = false; identSep.isHidden = false
            arcIcon.isHidden = false; arcName.isHidden = false
            // top band, stacked: "‹ Apps" → [big icon] Arc → rule → [emoji] Space name → rule.
            let bottomPad = floor            // rail sits above the footer
            let bandTop = b.height - 10 - searchH - 10
            let bt = NSAttributedString(string: "‹  Apps", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor])
            spaceBack.attributedTitle = bt
            let backW = ceil(bt.size().width) + 8
            spaceBack.frame = NSRect(x: 14, y: bandTop - spaceBackH, width: backW, height: spaceBackH)
            // identity block: big Arc icon + "Arc"
            let identTop = bandTop - spaceBackH - 6
            arcIcon.image = icon(for: "Arc")
            arcIcon.frame = NSRect(x: 14, y: identTop - arcIdentH + 3, width: 30, height: 30)
            arcName.frame = NSRect(x: 52, y: identTop - arcIdentH + 8, width: b.width - 68, height: 20)
            identSep.frame = NSRect(x: 16, y: identTop - arcIdentH - 8, width: b.width - 32, height: 1)
            // Space-name block: [emoji] name, prominent
            let titleTop = identSep.frame.minY - 8
            spaceTitle.frame = NSRect(x: 16, y: titleTop - spaceTitleH, width: b.width - 32, height: spaceTitleH)
            spaceSep.frame = NSRect(x: 16, y: spaceTitle.frame.minY - 8, width: b.width - 32, height: 1)
            spaceRail.frame = NSRect(x: 0, y: bottomPad, width: b.width, height: railH)
            let top = spaceSep.frame.minY - 8, bot = bottomPad + railH
            scroll.frame = NSRect(x: 4, y: bot, width: b.width - 8, height: max(0, top - bot))
            updateSpaceTitle(); buildSpaceRail()
        } else {
            spaceRail.isHidden = true; spaceTitle.isHidden = true
            spaceBack.isHidden = true; spaceSep.isHidden = true; identSep.isHidden = true
            arcIcon.isHidden = true; arcName.isHidden = true
            scroll.frame = NSRect(x: 4, y: floor, width: b.width - 8, height: b.height - searchH - 14 - floor)
        }
        // empty-state message centered over the (empty) list
        let sf = scroll.frame
        emptyLabel.frame = NSRect(x: sf.minX, y: sf.midY - 12, width: sf.width, height: 24)
        if rows.isEmpty {
            // a non-Arc drill-in always has ≥2 tabs (single-tab apps activate directly),
            // so the only reachable empties are: no search match, an empty Arc Space, no apps.
            if !search.stringValue.isEmpty { emptyLabel.stringValue = "No matches" }
            else if arcRailActive { emptyLabel.stringValue = "No tabs in this Space" }
            else { emptyLabel.stringValue = "Nothing to switch to" }
            emptyLabel.isHidden = false
        } else { emptyLabel.isHidden = true }
        updateBeam(b)
    }

    // OPEN border path: starts at top-left, sweeps clockwise across the top, down the
    // right edge, across the bottom, ending at bottom-left. The LEFT edge is intentionally
    // omitted — it's flush against the screen bezel (invisible) — so the beam covers the
    // three visible sides then pauses before reappearing at top-left. Rounded right corners.
    private func panelBeamPath(_ b: CGRect) -> CGPath {
        let r: CGFloat = 21
        let p = CGMutablePath()
        if anchorRight {                                              // mirror: round LEFT corners, skip the RIGHT edge
            p.move(to: CGPoint(x: b.maxX, y: b.maxY))                  // top-right (square)
            p.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY),
                     tangent2End: CGPoint(x: b.minX, y: b.minY), radius: r) // top edge + top-left (round)
            p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY),
                     tangent2End: CGPoint(x: b.maxX, y: b.minY), radius: r) // left edge + bottom-left (round)
            p.addLine(to: CGPoint(x: b.maxX, y: b.minY))              // bottom edge → bottom-right (square)
            return p                                                   // no right edge, no close
        }
        p.move(to: CGPoint(x: b.minX, y: b.maxY))                      // top-left (square)
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY),
                 tangent2End: CGPoint(x: b.maxX, y: b.minY), radius: r) // top edge + top-right (round)
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY),
                 tangent2End: CGPoint(x: b.minX, y: b.minY), radius: r) // right edge + bottom-right (round)
        p.addLine(to: CGPoint(x: b.minX, y: b.minY))                   // bottom edge → bottom-left (square)
        return p                                                       // no left edge, no close
    }
    private var beamPerim: CGFloat {
        let b = vibrant.bounds
        return 2 * (b.width + b.height) - 4 * 21 + .pi * 21            // full loop; the missing left edge = the pause
    }
    private func updateBeam(_ b: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)   // no implicit fade on path/frame
        beamView.frame = b
        let path = panelBeamPath(b.insetBy(dx: 1.5, dy: 1.5))
        let perim = beamPerim
        for (i, seg) in beamLayers.enumerated() {
            seg.frame = b
            seg.path = path
            // each segment is one dash, stepped `beamSeg` behind the previous; the dash is
            // ~2× the step so neighbours OVERLAP and their alphas blend into a smooth
            // gradient (no visible banding). Together they form one continuous comet.
            let dashLen = beamSeg * 2
            seg.lineDashPattern = [NSNumber(value: Double(dashLen)),
                                   NSNumber(value: Double(max(1, perim - dashLen)))]
            seg.lineDashPhase = CGFloat(i) * beamSeg
        }
        CATransaction.commit()
    }
    // One sweep around the panel, then the overlay hides again (invisible at rest).
    private func pulseBeam() {
        beamView.isHidden = false
        beamGen += 1; let gen = beamGen
        let a = CABasicAnimation(keyPath: "lineDashPhase")
        a.fromValue = 0; a.toValue = -beamPerim                        // one full cycle; left-edge span = an invisible pause
        a.duration = 5.0; a.repeatCount = 1
        a.isAdditive = true                                            // adds to each segment's base phase, keeping formation
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, gen == self.beamGen else { return } // a newer pulse superseded this one
            self.beamView.isHidden = true
        }
        for seg in beamLayers { seg.add(a, forKey: "beam") }
        CATransaction.commit()
    }
    // Sweep once on summon, then nudge again every 30s while the panel stays open.
    private func startBeam() {
        pulseBeam()
        beamPulseTimer?.invalidate()
        beamPulseTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.pulseBeam()
        }
    }
    private func stopBeam() {
        beamPulseTimer?.invalidate(); beamPulseTimer = nil
        for seg in beamLayers { seg.removeAnimation(forKey: "beam") }
        beamView.isHidden = true
    }
    private func resizeToContent() {
        guard let s = preferredScreen ?? NSScreen.main else { return }
        let vf = s.visibleFrame
        let rowsH = rows.reduce(0) { $0 + height($1) }
            + table.intercellSpacing.height * CGFloat(rows.count)   // 2px gap per row, else last row clips → scroll
        // In the Arc rail, lock content height to the tallest Space so switching Spaces
        // doesn't resize the panel; the switcher strip adds a fixed band on top.
        let innerH = arcRailActive ? arcRailInnerHeight() : rowsH
        // top band (‹ Arc + name + rule) + bottom switcher + paddings.
        let bands = arcRailActive ? (spaceBackH + arcIdentH + spaceTitleH + railH + 60) : 0
        var H = 10 + searchH + 10 + bands + innerH + 10 + footerH
        H = min(H, vf.height)                        // never taller than the screen (long lists scroll)
        H = max(H, vf.height * 0.60)                 // …but never a stub: floor at 60% (≈ the typical
                                                     //    panel height) so summons feel one consistent size
        H = round(H)
        let x = anchorRight ? vf.maxX - W : vf.minX   // mirror to the right edge on a right-side monitor
        panel.setFrame(NSRect(x: x, y: vf.maxY - H, width: W, height: H), display: true)
        layout()
    }

    // Resize: width only (clamped); height is locked to whatever content set.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: min(max(frameSize.width, minW), maxW), height: panel.frame.height)
    }
    func windowDidResize(_ notification: Notification) {
        let w = panel.frame.width
        guard abs(w - W) > 0.5 else { return }            // ignore our own programmatic setFrame
        W = min(max(w, minW), maxW)
        UserDefaults.standard.set(W, forKey: "panelWidth")
        table.reloadData(); layout()                      // re-render cells/headers at the new width
    }
    private func refresh(selectFirst: Bool = true) {
        buildRows(); table.reloadData(); resizeToContent()
        // Land on the first real item, not the (now-clickable) app header — drilling into an app
        // should still pre-select its first tab, so ⏎ picks a tab. Header falls back only if nothing else.
        if selectFirst {
            let f = rows.firstIndex { if case .appHeader = $0 { return false }; return selectable($0) }
                 ?? rows.firstIndex(where: selectable)
            if let f = f { selectRow(f) }
        }
    }

    // MARK: show / hide

    func toggle(source: String = "keyboard") {
        if visible { hide() } else { summonSource = source; edgeAutoClose = false; show() }
    }

    /// Edge trigger: summon on the screen the cursor pressed (no-op if already up).
    /// Auto-dismisses when the cursor leaves the panel (mouse intent, not keyboard).
    func summonAtEdge(_ screen: NSScreen) {
        guard !visible else { return }
        summonSource = "edge"; preferredScreen = screen; edgeAutoClose = true
        show()
        startEdgeHoverWatch()                             // close when the cursor leaves the panel rect
    }

    // Auto-close for edge-summon: close only when the cursor is OUTSIDE the panel's frame for a brief
    // grace. Pure mouse-vs-rect — no band, no specific location, no tracking-area enter/exit quirks.
    private func startEdgeHoverWatch() {
        edgeHoverPoll?.invalidate(); outsideSince = 0
        edgeHoverPoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.edgeHoverTick() }
    }
    private func edgeHoverTick() {
        guard edgeAutoClose, visible else { edgeHoverPoll?.invalidate(); return }
        if menuOpen { outsideSince = 0; return }                       // right-click menu up → stay open
        // Stay-open region is the FULL screen height at the panel's column (not the short content
        // frame), so moving the cursor up/down to reach a tab never closes it — you dismiss only by
        // moving AWAY from the edge (past the panel horizontally). Fixes short-panel premature close.
        let f = panel.frame
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? f
        let margin: CGFloat = 60
        let region = anchorRight
            ? NSRect(x: f.minX - margin, y: vf.minY, width: f.width + margin + 4, height: vf.height)   // leave leftward
            : NSRect(x: f.minX - 4,      y: vf.minY, width: f.width + 4 + margin, height: vf.height)    // leave rightward
        let inside = region.contains(NSEvent.mouseLocation)
        if inside {
            outsideSince = 0
        } else if outsideSince == 0 {
            outsideSince = CACurrentMediaTime()                       // just left → start the grace clock
        } else if CACurrentMediaTime() - outsideSince > 0.28 {
            hide()
        }
    }

    // NSMenuDelegate: pause edge auto-close while a context menu is open.
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; outsideSince = 0 }   // poll won't close while a menu is up
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // Right-click menu for a row — native NSMenu with an "Add to Context" submenu + per-row actions.
    private func rowMenu(_ r: Int) -> NSMenu? {
        guard rows.indices.contains(r) else { return nil }
        let m = NSMenu(); m.delegate = self
        switch rows[r] {
        case .tab(let ref):
            if case .context(let cid) = mode {
                // Already inside a context — offer to remove from THIS one, not "add to context".
                m.addItem(BlockMenuItem("Remove from Context") { [weak self] in self?.setTabMembership(ref, ctx: cid, member: false) })
            } else {
                let add = NSMenuItem(title: "Add to Context", action: nil, keyEquivalent: "")
                add.submenu = contextSubmenu(for: ref)
                m.addItem(add)
            }
            m.addItem(.separator())
            m.addItem(BlockMenuItem("Open") { [weak self] in self?.activateAndSelectClose(ref) })
            if let url = ref.url, !url.isEmpty {
                m.addItem(BlockMenuItem("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) })
            }
            if ref.close != nil { m.addItem(BlockMenuItem("Close Tab") { [weak self] in self?.closeTab(ref) }) }
        case .app(let name, _, _):
            m.addItem(BlockMenuItem(appPins.contains(name) ? "Unpin" : "Pin") { [weak self] in self?.togglePin(name) })
            if isBrowser(name) { m.addItem(BlockMenuItem("New Tab") { [weak self] in self?.newTab(in: name) }) }
            m.addItem(.separator())
            m.addItem(BlockMenuItem("Quit \(name)") { [weak self] in self?.quitApp(named: name) })
        case .context(_, _, let id, _):
            m.addItem(BlockMenuItem("Add Tabs…") { [weak self] in self?.openPick(id) })
            m.addItem(BlockMenuItem("Rename") { [weak self] in self?.openContextForRename(id) })
            let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            color.submenu = colorSubmenu(for: id)
            m.addItem(color)
            m.addItem(.separator())
            m.addItem(BlockMenuItem("Remove Context") { [weak self] in self?.removeContextAction(id) })
        default:
            return nil
        }
        return m.items.isEmpty ? nil : m
    }

    // "Add to Context" submenu: existing contexts (checked if this item is already in), then New.
    private func contextSubmenu(for ref: TabRef) -> NSMenu {
        let sub = NSMenu()
        let ctx = orderedContexts()
        for c in ctx {
            let inIt = store.isMember(ref, of: c.id)
            sub.addItem(BlockMenuItem(c.label, checked: inIt) { [weak self] in
                self?.setTabMembership(ref, ctx: c.id, member: !inIt)
            })
        }
        if !ctx.isEmpty { sub.addItem(.separator()) }
        sub.addItem(BlockMenuItem("New Context…") { [weak self] in self?.addToNewContext(ref) })
        return sub
    }

    // Rebuild the list in place, keeping the cursor near where it was.
    private func reloadPreservingSelection() {
        let sel = table.selectedRow
        buildRows(); table.reloadData(); resizeToContent()
        if rows.indices.contains(sel), selectable(rows[sel]) { selectRow(sel) }
        else if let i = rows.firstIndex(where: selectable) { selectRow(i) }
    }
    // Inline swatch picker (no system color panel): preset colors, current one checked, + reset.
    private func colorSubmenu(for id: String) -> NSMenu {
        let sub = NSMenu()
        let current = contextColor(for: id)
        for preset in contextColorPresets {
            let item = BlockMenuItem(preset.name) { [weak self] in self?.applyContextColor(id, preset.color) }
            item.image = colorSwatch(preset.color)
            item.state = colorsClose(preset.color, current) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        sub.addItem(BlockMenuItem("Reset to Default") { [weak self] in self?.applyContextColor(id, nil) })
        return sub
    }
    private func applyContextColor(_ id: String, _ color: NSColor?) {
        setContextColor(id, color)
        reloadPreservingSelection()
    }

    private func setTabMembership(_ ref: TabRef, ctx: String, member: Bool) {
        store.setMembership(ref, in: ctx, member: member)
        UsageLog.shared.log(member ? "ctxadd" : "ctxremove", ["id": ctx, "app": ref.app, "via": "rightclick"])
        reloadPreservingSelection()
    }
    private func addToNewContext(_ ref: TabRef) {
        let id = store.createContext(named: "New context")
        store.setMembership(ref, in: id, member: true)
        UsageLog.shared.log("ctxcreate", ["id": id, "via": "rightclick"])
        openContextForRename(id)
    }
    private func activateAndSelectClose(_ ref: TabRef) { activateAndSelect(ref); hide() }
    private func openPick(_ id: String) { mode = .pick(id); search.stringValue = ""; refresh(); focusContextName() }
    private func openContextForRename(_ id: String) {
        noteContextViewed(id); mode = .context(id); search.stringValue = ""; refresh(); focusContextName()
    }
    private func removeContextAction(_ id: String) {
        store.removeContext(id)
        UsageLog.shared.log("ctxdelete", ["id": id])
        if case .context(let cur) = mode, cur == id { mode = .apps }   // were viewing it → back out
        if case .pick(let cur) = mode, cur == id { mode = .apps }
        reloadPreservingSelection()
    }
    private func quitApp(named name: String) {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            UsageLog.shared.log("quitapp", ["app": name, "via": "rightclick"]); running.terminate()
            all.removeAll { $0.app == name }; appOrder.removeAll { $0 == name }
            buildRows(); table.reloadData(); resizeToContent()
        }
    }

    // The frontmost normal app window whose center lies on `screen`, or nil. Uses window metadata
    // (owner/bounds/layer) — no screen-recording permission needed (we don't read titles/images).
    private func frontAppOnScreen(_ screen: NSScreen) -> String? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for w in infos {                                                  // front-to-back z-order
            guard (w[kCGWindowLayer as String] as? Int) == 0,            // normal app windows only
                  let pid = w[kCGWindowOwnerPID as String] as? Int, Int32(pid) != selfPID,  // not our panel
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let bw = b["Width"], let bh = b["Height"], bw > 40, bh > 40
            else { continue }
            // window center: CGWindow bounds are top-left origin (primary-relative) → NS bottom-left.
            let center = NSPoint(x: x + bw / 2, y: primaryH - (y + bh / 2))
            guard NSMouseInRect(center, screen.frame, false) else { continue }
            // Resolve PID → localizedName so it matches our app naming ("iTerm2", not CGWindow's "iTerm").
            return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
        }
        return nil
    }

    // The screen the cursor is on (dual-monitor: summon where you're actually working, not always main).
    private func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    func show() {
        // Keyboard summon (no edge-trigger screen) → appear on the screen under the cursor.
        if preferredScreen == nil { preferredScreen = screenUnderMouse() }
        // Mirror to the right edge on a monitor whose left side is the internal boundary.
        anchorRight = (preferredScreen ?? NSScreen.main).map(anchorRightFor) ?? false
        vibrant.maskImage = anchorRight ? Self.leftRoundedMask(radius: 22) : Self.rightRoundedMask(radius: 22)
        all = allContexts()
        if showContexts { store.ingest(all) }   // sync contexts to this summon's scan (no second scan)
        if isRunning("Arc") {
            activeArcSpace = arcActiveSpace()
            arcSpacesCache = arcSpaceList()          // includes spaces with no open tabs
            arcEmojiCache = arcSpaceEmojiMap()
        } else {
            activeArcSpace = nil; arcSpacesCache = []; arcEmojiCache = [:]
        }
        selectedSpace = nil                          // each summon defaults to the active Space
        let fm = NSWorkspace.shared.frontmostApplication
        let isSelfFront = fm?.bundleIdentifier == Bundle.main.bundleIdentifier
        // If we're already frontmost (from a prior summon), target the last real app instead;
        // otherwise this IS the real app — remember it for next time (seeds the case where the
        // activation observer never fired).
        if !isSelfFront, let real = fm?.localizedName { lastFrontApp = real; recordAppUse(real) }
        // The "current app" is the frontmost app ON THE SUMMONED SCREEN (so a dual-monitor summon
        // matches the monitor you're on), falling back to the global frontmost.
        var front = isSelfFront ? lastFrontApp : fm?.localizedName
        if let s = preferredScreen, let onScreen = frontAppOnScreen(s) { front = onScreen }
        rebuildAppOrder()                            // enumeration → MRU → pinned-first
        search.stringValue = ""
        // Landing priority:
        // 1. the active tab belongs to a context → open that context (most-recent if several),
        // 2. else an app with tabs → dive into its tab list,
        // 3. else the Apps screen.
        if let ctxId = contextOfActiveTab(front) {
            mode = .context(ctxId); noteContextViewed(ctxId)
        } else if let f = front, appOrder.contains(f), all.filter({ $0.app == f }).count > 1 {
            mode = .tabs(f)
        } else {
            mode = .apps
        }
        didPick = false
        let landed: String = { switch mode { case .tabs: return "tabs"; case .context: return "context"; default: return "apps" } }()
        UsageLog.shared.log("summon", ["trigger": summonSource, "mode": landed,
                                       "apps": appOrder.count, "rows": all.count])
        panel.alphaValue = 0
        refresh(selectFirst: false)                          // builds rows + sets the final frame
        let activeTab = front.flatMap { activeTitle($0) }
        let inTabsOrContext: Bool = { switch mode { case .tabs, .context: return true; default: return false } }()
        // In tabs OR a context view, land on the active tab; else pre-select the app you came from.
        if inTabsOrContext, let app = front, let at = activeTab,
           let i = rows.firstIndex(where: { if case .tab(let r) = $0 { return r.app == app && r.title == at }; return false }) {
            selectRow(i)
        } else if let f = front, let i = appRowIndex(f) {
            selectRow(i)
        } else if let i = rows.firstIndex(where: selectable) {
            selectRow(i)
        }

        // sleek entrance: slide in from the anchored edge (left, or right when mirrored) + fade
        let finalFrame = panel.frame
        panel.setFrame(finalFrame.offsetBy(dx: anchorRight ? 28 : -28, dy: 0), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
        visible = true
        startBeam()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        clickAway = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.hide()
        }
        // ⌘Tab (or any switch) to another app dismisses the panel — it's a momentary summon.
        appSwitchObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }  // ignore our own activation
            self?.hide()
        }
    }
    func hide() {
        guard visible else { return }
        if !didPick { UsageLog.shared.log("dismiss", ["trigger": summonSource]) }  // summoned but nothing chosen
        visible = false
        stopBeam()
        preferredScreen = nil                            // next summon recomputes (edge screen, else screen under cursor)
        edgeAutoClose = false; edgeHoverPoll?.invalidate(); edgeHoverPoll = nil; outsideSince = 0
        if let m = clickAway { NSEvent.removeMonitor(m); clickAway = nil }
        if let o = appSwitchObs { NSWorkspace.shared.notificationCenter.removeObserver(o); appSwitchObs = nil }
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(f.offsetBy(dx: -22, dy: 0), display: true)
        }, completionHandler: { [weak self] in
            guard let self = self, !self.visible else { return }   // re-shown mid-animation? keep it
            self.panel.orderOut(nil); self.panel.alphaValue = 1
        })
    }

    // MARK: search / keyboard

    func controlTextDidChange(_ obj: Notification) { searchLogo.isHidden = !search.stringValue.isEmpty; refresh() }

    private let titleFont = NSFont.systemFont(ofSize: 13)

    /// Draw a rounded translucent "chip" (faint fill + soft border) behind each
    /// occurrence of the search query in a title — measured against the title font so
    /// the chip wraps exactly the matched characters. Added before the title label so
    /// the text sits on top.
    private func addMatchChips(to cell: NSView, text: String, titleFrame: NSRect) {
        let query = search.stringValue
        guard !query.isEmpty else { return }
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: titleFont]
        var range = NSRange(location: 0, length: ns.length)
        let padX: CGFloat = 3, chipH: CGFloat = 17
        let textInset: CGFloat = 2     // NSTextField label draws text ~2px in from its frame edge
        while true {
            let m = ns.range(of: query, options: .caseInsensitive, range: range)
            if m.location == NSNotFound { break }
            let prefixW = ns.substring(to: m.location).size(withAttributes: attrs).width
            let matchW = ns.substring(with: m).size(withAttributes: attrs).width
            let chip = NSView(frame: NSRect(
                x: titleFrame.minX + textInset + prefixW - padX,
                y: titleFrame.minY + (titleFrame.height - chipH) / 2,
                width: matchW + padX * 2, height: chipH))
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 4
            chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
            cell.addSubview(chip)
            let next = m.location + m.length
            range = NSRange(location: next, length: ns.length - next)
        }
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):      move(1);  return true
        case #selector(NSResponder.moveUp(_:)):        move(-1); return true
        case #selector(NSResponder.moveRight(_:)):     drillIn(); return true
        case #selector(NSResponder.moveLeft(_:)):      goBack();  return true
        case #selector(NSResponder.insertNewline(_:)): activate(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): onEscape(); return true
        default: return false
        }
    }

    private func onEscape() {
        // Launcher convention: esc dismisses. First esc clears a query; otherwise close
        // from anywhere (back-a-level is on ← and the "‹ Apps" button, not esc).
        if !search.stringValue.isEmpty { search.stringValue = ""; refresh() }
        else { hide() }
    }
    private func goBack() {
        switch mode {
        case .pick(let id):
            store.discardIfEmpty(id); mode = .apps; search.stringValue = ""
            slideDrill(.fromLeft); refresh(selectFirst: false); reselectAfterBack(contextId: id)
        case .tabs(let app):
            mode = .apps; search.stringValue = ""
            slideDrill(.fromLeft); refresh(selectFirst: false); reselectAfterBack(app: app)
        case .context(let id):
            mode = .apps; search.stringValue = ""
            slideDrill(.fromLeft); refresh(selectFirst: false); reselectAfterBack(contextId: id)
        case .apps: break
        }
    }
    // Put the cursor in the context-name field (after creating a context) so it's ready to rename.
    private func focusContextName() {
        guard let r = rows.firstIndex(where: { if case .contextHeader = $0 { return true }; return false }),
              let cell = table.view(atColumn: 0, row: r, makeIfNecessary: true),
              let field = cell.subviews.compactMap({ $0 as? RenameField }).first else { return }
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    private func open(app: String) { mode = .tabs(app); search.stringValue = ""; refresh() }

    // Contexts in presentation order: most-recently-used first (by the best MRU rank among a
    // context's apps), falling back to the engine's stable order (app-count, then size) on ties.
    // Contexts in their stable creation order (the store owns the ordering). No MRU/recency sort —
    // contexts must stay put so you build spatial memory of where each one lives.
    private func orderedContexts() -> [WorkContext] { store?.contexts ?? [] }
    private func contextRow(_ c: WorkContext) -> Row {
        .context(label: c.label, apps: c.apps, id: c.id, aiLabeled: c.aiLabeled)
    }

    // Recency of opened contexts (session) — tiebreaker when an active tab belongs to more than one.
    private var contextMRU: [String] = []
    private func noteContextViewed(_ id: String) {
        contextMRU.removeAll { $0 == id }; contextMRU.insert(id, at: 0)
    }
    // The context to open for the app you're in (if any), so summon drops you into your working
    // context. Most-recently-viewed wins when several qualify (else creation order).
    private func contextOfActiveTab(_ frontApp: String?) -> String? {
        guard showContexts, let app = frontApp else { return nil }
        let contexts = store?.contexts ?? []
        let rank = Dictionary(contextMRU.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func best(_ cs: [WorkContext]) -> String? {
            cs.isEmpty ? nil : cs.min { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }?.id
        }
        // Browsers/iTerm expose the active tab → use ITS context precisely (nil → caller dives into
        // the app's tabs, so we don't jump to an unrelated context the app merely participates in).
        if let title = activeTitle(app), let ref = all.first(where: { $0.app == app && $0.title == title }) {
            return best(contexts.filter { c in c.members.contains { $0.app == ref.app && $0.title == ref.title } })
        }
        // Apps that expose no scriptable active tab (non-AppleScript apps, plugin-backed targets) →
        // any context this app is part of. This is why it didn't resolve for those apps before.
        return best(contexts.filter { c in c.members.contains { $0.app == app } })
    }

    // True only while a context NAME is being edited (the field editor's delegate is a RenameField) —
    // NOT the always-focused Search field. Used so a table rebuild doesn't interrupt a rename.
    private var isEditingContextName: Bool {
        ((panel.firstResponder as? NSTextView)?.delegate as? RenameField) != nil
    }

    // The engine published new/updated contexts. Re-render in place (preserving selection) when
    // they're actually on screen — the Apps list or a context drill-in, and not mid-search.
    private func contextsDidChange() {
        guard visible, search.stringValue.isEmpty else { return }
        if isEditingContextName { return }   // don't blow away an in-progress inline rename
        switch mode {
        case .apps, .context:
            let sel = table.selectedRow
            buildRows(); table.reloadData(); resizeToContent()
            if rows.indices.contains(sel), selectable(rows[sel]) { selectRow(sel) }
        case .tabs, .pick: break   // pick-mode manages its own rebuilds (don't disturb toggling)
        }
    }
    // Favicons arrive async and in bursts; coalesce them into one redraw of the visible rows so
    // cached icons actually paint (the cell they originally loaded into may already be gone).
    private var iconRefreshPending = false
    private func scheduleIconRefresh() {
        guard visible, !iconRefreshPending else { return }
        iconRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.iconRefreshPending = false
            guard self.visible, !self.isEditingContextName else { return }   // don't disrupt a rename (Search focus is fine)
            let visibleRange = self.table.rows(in: self.table.visibleRect)
            if visibleRange.length > 0 { self.table.reloadData(forRowIndexes: IndexSet(integersIn: Range(visibleRange)!), columnIndexes: IndexSet(integer: 0)) }
        }
    }

    // Inline rename committed in the context header → persist (durable) and recompute.
    private func renameContext(_ id: String, to label: String) {
        UsageLog.shared.log("ctxrename", ["id": id])
        store.rename(id, to: label)
    }

    // Most-recently-used app tracking (app-level only; tabs stay in native order — Arc
    // spaces/folders and browser tab strips are the user's own arrangement).
    private func recordAppUse(_ name: String) {
        appMRU.removeAll { $0 == name }
        appMRU.insert(name, at: 0)
        if appMRU.count > 50 { appMRU = Array(appMRU.prefix(50)) }
        UserDefaults.standard.set(appMRU, forKey: "appMRU")
    }
    private func sortByMRU(_ apps: inout [String]) {
        let rank = Dictionary(appMRU.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let orig = Dictionary(apps.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        apps.sort {
            let r0 = rank[$0] ?? Int.max, r1 = rank[$1] ?? Int.max
            if r0 != r1 { return r0 < r1 }
            return (orig[$0] ?? 0) < (orig[$1] ?? 0)   // ties: keep enumeration order (stable)
        }
    }
    /// Build appOrder from the live contexts: enumeration → MRU → pinned-first (pin order).
    private func rebuildAppOrder() {
        var seen = Set<String>(); appOrder = []
        for r in all where !seen.contains(r.app) { seen.insert(r.app); appOrder.append(r.app) }
        sortByMRU(&appOrder)
        let pinnedSet = Set(appPins)
        appOrder = appPins.filter { appOrder.contains($0) }          // pinned, in pin order
                 + appOrder.filter { !pinnedSet.contains($0) }       // then the MRU rest
    }
    private func togglePin(_ name: String) {
        // newest pin goes to the TOP, so "unpin + re-pin" is how you promote a pin (no drag needed)
        if let i = appPins.firstIndex(of: name) { appPins.remove(at: i) } else { appPins.insert(name, at: 0) }
        UserDefaults.standard.set(appPins, forKey: "appPins")
        UsageLog.shared.log("pin", ["app": name, "pinned": appPins.contains(name)])
        let old = rows
        rebuildAppOrder(); buildRows()                              // self.rows = new layout
        animateRowChange(from: old, movedApp: name)                 // glide the app up/down, slide the rest
        resizeToContent()
        if let i = appRowIndex(name) { selectRow(i) }               // keep the same app selected after reorder
    }
    /// Identity for diffing rows across a pin toggle (so the table can animate the change).
    private func rowKey(_ r: Row) -> String {
        switch r {
        case .app(let n, _, _):            return "app:\(n)"
        case .header(let s, _, _):         return "hdr:\(s)"
        case .rule:                        return "rule"
        case .newTab(let a):               return "newtab:\(a)"
        case .back:                        return "back"
        case .appHeader(let a):            return "apphdr:\(a)"
        case .folderHeader(_, let k, _):   return "folder:\(k)"
        case .splitHeader(_, let k, _, _): return "split:\(k)"
        case .tab(let t):                  return "tab:\(t.app):\(t.title)"
        case .context(_, _, let id, _): return "ctx:\(id)"
        case .contextHeader(let id, _):    return "ctxhdr:\(id)"
        case .newContext:                  return "newctx"
        case .addTabs(let id):             return "addtabs:\(id)"
        case .pickDone:                    return "pickdone"
        case .pickItem(let t, _):          return "pick:\(t.app):\(t.title)"
        }
    }
    /// Animate a single-app pin toggle: the "Pinned" header/rule slide in/out and the
    /// toggled app glides to its new slot (the rest reflow automatically).
    private func animateRowChange(from old: [Row], movedApp: String) {
        // rowKey isn't unique for structural rows — every `.rule` keys to "rule", and pinning adds a
        // SECOND rule (+ a "Pinned" header). A Set/Dictionary diff would collapse the duplicate keys
        // and under-count the inserts, desyncing NSTableView (ghost row + blank gap). Disambiguate
        // duplicates by occurrence order so the diff is an exact multiset delta; stable rows still
        // match (a row present in both at the same occurrence keeps its identity), so the glide holds.
        func uniq(_ keys: [String]) -> [String] {
            var seen: [String: Int] = [:]
            return keys.map { k in let n = seen[k, default: 0]; seen[k] = n + 1; return n == 0 ? k : "\(k)#\(n)" }
        }
        let oldKeys = uniq(old.map(rowKey)), newKeys = uniq(rows.map(rowKey))
        let oldSet = Set(oldKeys), newSet = Set(newKeys)
        let oldIdx = Dictionary(oldKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let newIdx = Dictionary(newKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let deletes = oldKeys.enumerated().compactMap { newSet.contains($0.element) ? nil : $0.offset }  // pre-update
        let inserts = newKeys.enumerated().compactMap { oldSet.contains($0.element) ? nil : $0.offset }  // post-update
        table.beginUpdates()
        if !deletes.isEmpty { table.removeRows(at: IndexSet(deletes), withAnimation: [.effectFade, .slideUp]) }
        if !inserts.isEmpty { table.insertRows(at: IndexSet(inserts), withAnimation: [.effectFade, .slideDown]) }
        let key = "app:\(movedApp)"
        if let f = oldIdx[key], let t = newIdx[key], f != t { table.moveRow(at: f, to: t) }
        table.endUpdates()
    }
    private func appRowIndex(_ name: String) -> Int? {
        rows.firstIndex { if case .app(let n, _, _) = $0 { return n == name }; return false }
    }
    private func drillIn() {
        let r = table.selectedRow
        guard r >= 0, r < rows.count else { return }
        // → drills into a container (app or context). For an app, activate() drills in when
        // multi-tab, else goes straight to the single tab. For a context, it opens the context.
        switch rows[r] {
        case .app, .context: slideDrill(.fromRight); activate(r)   // push: new level enters from the right
        default: break                                             // leaves (tabs/actions) ignore →
        }
    }

    /// Slide the list when drilling the hierarchy, so → / swipe feel like a push/pop. Animates the
    /// clip view's layer; the reload that follows is what gets pushed in.
    private func slideDrill(_ subtype: CATransitionSubtype) {
        let clip = scroll.contentView
        clip.wantsLayer = true
        let t = CATransition()
        t.type = .push; t.subtype = subtype
        t.duration = 0.20
        t.timingFunction = CAMediaTimingFunction(name: .easeOut)
        clip.layer?.add(t, forKey: "drill")
    }

    /// After popping back to the app list, re-highlight the app/context we came from (not row 0),
    /// so the row you drilled into stays under focus. Falls back to the first selectable row.
    private func reselectAfterBack(app: String? = nil, contextId: String? = nil) {
        let idx = rows.firstIndex { row in
            switch row {
            case .app(let name, _, _):       return app != nil && name == app
            case .context(_, _, let id, _):  return contextId != nil && id == contextId
            default:                          return false
            }
        }
        if let i = idx { selectRow(i) }
        else if let f = rows.firstIndex(where: selectable) { selectRow(f) }
    }

    private func selectRow(_ i: Int) {
        guard i >= 0, i < rows.count else { return }
        table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i)
    }
    private func move(_ d: Int) {
        var r = (table.selectedRow < 0 ? -1 : table.selectedRow) + d
        while r >= 0 && r < rows.count && !selectable(rows[r]) { r += d }
        if r >= 0 && r < rows.count { selectRow(r) }
    }
    private func activate(_ r: Int) {
        guard r >= 0, r < rows.count else { return }
        switch rows[r] {
        case .app(let name, _, let count):
            if count > 1 {
                open(app: name)                          // multiple tabs → drill in (not a final pick)
            } else if let only = all.first(where: { $0.app == name }) {
                logPick("app", app: name, index: r); activateAndSelect(only); hide()
            } else {
                logPick("app", app: name, index: r); activateApp(name); hide()
            }
        case .tab(let ref):        logPick("tab", app: ref.app, index: r, key: ContextKey.key(ref)); activateAndSelect(ref); hide()
        case .newTab(let app):
            let priv = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false   // ⌘-click → private
            newTab(in: app, private: priv)
        case .back:                goBack()
        case .folderHeader(_, let key, _):
            toggleFolder(key)
            buildRows(); table.reloadData(); resizeToContent()   // re-render with the folder open/closed
        case .splitHeader(_, let key, _, _):
            toggleSplit(key)
            buildRows(); table.reloadData(); resizeToContent()
        case .context(_, _, let id, _):
            noteContextViewed(id)
            mode = .context(id); search.stringValue = ""; refresh()   // drill into the context
        case .newContext:
            let id = store.createContext(named: "New context")
            UsageLog.shared.log("ctxcreate", ["id": id])
            mode = .pick(id); search.stringValue = ""; refresh()
            focusContextName()                                        // ready to rename immediately
        case .addTabs(let id):
            mode = .pick(id); search.stringValue = ""; refresh()
        case .pickDone:
            if case .pick(let id) = mode { store.discardIfEmpty(id) }  // abandoned empties vanish
            mode = .apps; search.stringValue = ""; refresh()
        case .pickItem(let ref, let on):
            if case .pick(let id) = mode {
                store.setMembership(ref, in: id, member: !on)
                UsageLog.shared.log(on ? "ctxremove" : "ctxadd", ["id": id, "app": ref.app, "key": ContextKey.assignmentKey(ref)])
                let sel = table.selectedRow
                buildRows(); table.reloadData(); resizeToContent()    // re-render the toggled checkbox
                if rows.indices.contains(sel) { selectRow(sel) }
            }
        case .contextHeader: focusContextName()   // click the header → edit the name
        case .appHeader(let app):
            logPick("app", app: app, index: r); activateApp(app); hide()     // header click → bring the app forward at its active tab
        case .header, .rule: break
        }
    }
    private func logPick(_ kind: String, app: String, index: Int, key: String? = nil) {
        didPick = true
        let m: String = { switch mode { case .tabs: return "tabs"; case .context: return "context"; case .pick: return "pick"; case .apps: return "apps" } }()
        var fields: [String: Any] = ["kind": kind, "app": app, "index": index,
                                     "query": search.stringValue, "searched": !search.stringValue.isEmpty,
                                     "mode": m, "trigger": summonSource]
        if let key = key { fields["ctxKey"] = key }     // context key of the picked item → behavioral signal for AI
        UsageLog.shared.log("pick", fields)
    }
    // Open a new tab in a browser (from the "+ New tab" row). ⌘-click → new private
    // window (browsers have no per-tab incognito). Dismisses the panel.
    private func newTab(in app: String, private isPrivate: Bool = false) {
        UsageLog.shared.log("newtab", ["app": app, "private": isPrivate])
        openNewBrowserTab(app, private: isPrivate); hide()
    }
    // Close a tab (from the hover-×): run the adapter's close, drop it from our snapshot,
    // and refresh in place — the panel stays open.
    private func closeTab(_ ref: TabRef) {
        guard let close = ref.close else { return }
        close()
        all.removeAll { $0.app == ref.app && $0.title == ref.title && $0.url == ref.url }
        UsageLog.shared.log("closetab", ["app": ref.app])
        let sel = table.selectedRow
        buildRows(); table.reloadData(); resizeToContent()
        if rows.indices.contains(sel), selectable(rows[sel]) { selectRow(sel) }      // keep cursor near
        else if let i = rows.firstIndex(where: selectable) { selectRow(i) }
    }
    // ⌘Q: quit the target app (the one you're drilled into, or the selected app row),
    // gracefully so it can prompt for unsaved work. Removes it from the list, panel stays.
    private func quitTarget() {
        var name: String?
        switch mode {
        case .tabs(let app): name = app
        case .apps, .context, .pick:
            // selected row → its app (an app row in .apps, or a tab's app inside a context/pick)
            let r = table.selectedRow
            if r >= 0, r < rows.count {
                if case .app(let n, _, _) = rows[r] { name = n }
                else if case .tab(let ref) = rows[r] { name = ref.app }
                else if case .pickItem(let ref, _) = rows[r] { name = ref.app }
            }
        }
        guard let appName = name,
              let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName })
        else { return }
        UsageLog.shared.log("quitapp", ["app": appName])
        running.terminate()                                  // graceful (not forceTerminate)
        all.removeAll { $0.app == appName }; appOrder.removeAll { $0 == appName }
        if case .tabs(let a) = mode, a == appName { mode = .apps; search.stringValue = "" }
        buildRows(); table.reloadData(); resizeToContent()
        if let i = rows.firstIndex(where: selectable) { selectRow(i) }
    }
    @objc private func rowClicked() { activate(table.clickedRow) }
    @objc private func openSettings() { hide(); onOpenSettings?() }
    private func focusSearch() {
        panel.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)            // jump to search, ready to type
    }

    // MARK: data / views

    // Apple Intelligence glyph if the OS has it, else the generic "sparkles" AI mark.
    private lazy var aiGlyph: NSImage? =          // subtle badge shown after an AI-named context
        NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI")?   // clearer than the
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))    // apple.intelligence swirl, which read as an ×
    // The context marker — one calm leading glyph per context row (replaces the busy app-icon stack).
    private lazy var contextGlyph: NSImage? =
        NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "context")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))

    // Shared "+ action" row (New tab / New context / Add tabs): plus glyph, label, optional right hint.
    // Resizable mask that rounds only the RIGHT corners (radius r); left edge square/flush.
    // capInsets keep the corners crisp while the 1px center stretches to any panel size.
    static func rightRoundedMask(radius r: CGFloat) -> NSImage {
        let w = r + 2, h = r * 2 + 1
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: 0))                              // bottom-left (square)
            p.line(to: NSPoint(x: 0, y: h))                             // up to top-left (square)
            p.appendArc(from: NSPoint(x: w, y: h), to: NSPoint(x: w, y: 0), radius: r)  // round top-right
            p.appendArc(from: NSPoint(x: w, y: 0), to: NSPoint(x: 0, y: 0), radius: r)  // round bottom-right
            p.close()
            NSColor.black.set(); p.fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: 1, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
    // Mirror: rounds only the LEFT corners (for a panel anchored to a screen's right edge).
    static func leftRoundedMask(radius r: CGFloat) -> NSImage {
        let w = r + 2, h = r * 2 + 1
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: w, y: 0))                             // bottom-right (square)
            p.line(to: NSPoint(x: w, y: h))                            // up to top-right (square)
            p.appendArc(from: NSPoint(x: 0, y: h), to: NSPoint(x: 0, y: 0), radius: r)  // round top-left
            p.appendArc(from: NSPoint(x: 0, y: 0), to: NSPoint(x: w, y: 0), radius: r)  // round bottom-left
            p.close()
            NSColor.black.set(); p.fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: 1)
        img.resizingMode = .stretch
        return img
    }
    // Right-anchored when a screen sits immediately to this one's LEFT (its left edge is internal),
    // so its exposed/physical edge is the right — matches the EdgeTrigger.
    private func anchorRightFor(_ s: NSScreen) -> Bool {
        let f = s.frame
        return NSScreen.screens.contains { o in
            o !== s && o.frame.minY < f.maxY && o.frame.maxY > f.minY && abs(o.frame.maxX - f.minX) < 2
        }
    }

    // Small tertiary glyph that leads a section header (Pinned, Contexts, …). One place so they match.
    private func sectionGlyph(_ symbol: String) -> NSImageView {
        let iv = NSImageView(frame: NSRect(x: 16, y: 3, width: 13, height: 13))
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        iv.contentTintColor = .tertiaryLabelColor; iv.imageScaling = .scaleProportionallyDown
        return iv
    }

    private func plusRow(glyph: String, text: String, hint: String?) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: tabRowH))
        let pi = NSImageView(frame: NSRect(x: 16, y: 11, width: 18, height: 18))
        pi.image = NSImage(systemSymbolName: glyph, accessibilityDescription: text)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        pi.contentTintColor = .secondaryLabelColor; pi.imageScaling = .scaleProportionallyDown
        v.addSubview(pi)
        let lbl = NSTextField(labelWithString: text)
        lbl.font = titleFont; lbl.textColor = .secondaryLabelColor
        lbl.frame = NSRect(x: 42, y: 11, width: W - 150, height: 18); v.addSubview(lbl)
        if let hint = hint {
            let h = NSTextField(labelWithString: hint)
            h.font = .systemFont(ofSize: 10.5); h.textColor = .tertiaryLabelColor
            h.alignment = .right; h.frame = NSRect(x: W - 130, y: 12, width: 114, height: 15); v.addSubview(h)
        }
        return v
    }

    private func icon(for app: String) -> NSImage? {
        if let c = iconCache[app] { return c }
        let img = NSWorkspace.shared.runningApplications.first { $0.localizedName == app }?.icon
        if let img = img { iconCache[app] = img }
        return img
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, heightOfRow r: Int) -> CGFloat { height(rows[r]) }
    func tableView(_ t: NSTableView, rowViewForRow r: Int) -> NSTableRowView? { PillRowView() }
    func tableView(_ t: NSTableView, shouldSelectRow r: Int) -> Bool { selectable(rows[r]) }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row r: Int) -> NSView? {
        let cell = NSView()
        switch rows[r] {
        case .app(let name, let sub, let count):
            let appCell = AppCell()                      // hosts a hover-revealed, clickable pin
            let hasSub = !sub.isEmpty && sub != name
            let iv = NSImageView(frame: NSRect(x: 14, y: 13, width: 28, height: 28))
            iv.image = icon(for: name); iv.imageScaling = .scaleProportionallyUpOrDown; appCell.addSubview(iv)
            // stop the text before the count (and before the right-edge pin) so a long
            // title/subtitle never crowds the number.
            let textW = W - 100 - (count > 1 ? 60 : 0)   // leave room for the magnitude bar + small count
            let title = NSTextField(labelWithString: name)
            title.font = .systemFont(ofSize: 14, weight: .semibold); title.textColor = .labelColor
            // two-line layout when there's a subtitle; otherwise vertically centered with the icon.
            title.frame = NSRect(x: 52, y: hasSub ? 28 : 18, width: textW, height: 18); title.lineBreakMode = .byTruncatingTail
            title.toolTip = hasSub ? "\(name) — \(sub)" : name      // full text on hover (no marquee)
            appCell.addSubview(title)
            if hasSub {
                let s = NSTextField(labelWithString: sub)
                s.font = .systemFont(ofSize: 11); s.textColor = .secondaryLabelColor
                s.frame = NSRect(x: 52, y: 9, width: textW, height: 15); s.lineBreakMode = .byTruncatingTail
                s.toolTip = sub
                appCell.addSubview(s)
            }
            if count > 1 {
                // magnitude bar (fills toward ~25 tabs = "a lot") + a small precise count at its end.
                let frac = min(1.0, CGFloat(count) / 25.0)
                let track = NSView(frame: NSRect(x: W - 98, y: 24, width: 30, height: 5))
                track.wantsLayer = true; track.layer?.cornerRadius = 2.5
                track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
                let fill = NSView(frame: NSRect(x: 0, y: 0, width: max(3, 30 * frac), height: 5))
                fill.wantsLayer = true; fill.layer?.cornerRadius = 2.5
                fill.layer?.backgroundColor = NSColor(srgbRed: 0.94, green: 0.71, blue: 0.33, alpha: 1).cgColor
                track.addSubview(fill); appCell.addSubview(track)
                let c = NSTextField(labelWithString: "\(count)")
                c.font = .systemFont(ofSize: 11, weight: .semibold); c.textColor = .secondaryLabelColor
                c.alignment = .right; c.frame = NSRect(x: W - 64, y: 19, width: 20, height: 15); appCell.addSubview(c)
            }
            appCell.pinned = appPins.contains(name)      // pinned → always shown; else fades in on hover
            appCell.pin.frame = NSRect(x: W - 44, y: 17, width: 20, height: 20)
            appCell.onTogglePin = { [weak self] in self?.togglePin(name) }
            return appCell
        case .back:
            // plain escape hatch — no app icon (the identity header below carries that).
            let lbl = NSTextField(labelWithString: "‹  Apps")
            lbl.font = .systemFont(ofSize: 12, weight: .medium); lbl.textColor = .secondaryLabelColor
            lbl.frame = NSRect(x: 14, y: 4, width: W - 28, height: 16); cell.addSubview(lbl)
        case .appHeader(let app):
            // identity: bigger app icon + name + tab count, telling you which app you're inside.
            let iv = NSImageView(frame: NSRect(x: 14, y: 6, width: 28, height: 28))
            iv.image = icon(for: app); iv.imageScaling = .scaleProportionallyUpOrDown; cell.addSubview(iv)
            let lbl = NSTextField(labelWithString: app)
            lbl.font = .systemFont(ofSize: 15, weight: .semibold); lbl.textColor = .labelColor
            lbl.frame = NSRect(x: 50, y: 10, width: W - 150, height: 20); lbl.lineBreakMode = .byTruncatingTail
            cell.addSubview(lbl)
            let nTabs = rows.reduce(0) { if case .tab = $1 { return $0 + 1 }; return $0 }   // tabs shown in this app
            // Messages is a capped recent window, not the full list — say "recent" so it doesn't read as a total.
            let cnt = NSTextField(labelWithString: app == "Messages" ? "\(nTabs) recent"
                                                                     : (nTabs == 1 ? "1 tab" : "\(nTabs) tabs"))
            cnt.font = .systemFont(ofSize: 12); cnt.textColor = .tertiaryLabelColor
            cnt.alignment = .right; cnt.frame = NSRect(x: W - 92, y: 12, width: 78, height: 16); cell.addSubview(cnt)
        case .header(let group, let icon, let active):
            // Space header: emoji (from Arc) + the space name (drop the redundant "App · " prefix).
            // The active Space is brighter, with an accent dot. The "Pinned" section gets a pin glyph.
            let spaceName = group.components(separatedBy: " · ").last ?? group
            var lx: CGFloat = 16
            if group == "Pinned" {
                cell.addSubview(sectionGlyph("pin.fill")); lx = 36
            } else if group == "Contexts" {
                cell.addSubview(sectionGlyph("square.stack.3d.up.fill")); lx = 36
            } else if let ic = icon {
                let emoji = NSTextField(labelWithString: ic)
                emoji.font = .systemFont(ofSize: 12)
                emoji.frame = NSRect(x: 16, y: 3, width: 16, height: 16); cell.addSubview(emoji); lx = 36
            }
            let lbl = NSTextField(labelWithString: spaceName.uppercased())
            lbl.font = .systemFont(ofSize: 10.5, weight: active ? .bold : .semibold)
            lbl.textColor = active ? .labelColor : .tertiaryLabelColor
            lbl.frame = NSRect(x: lx, y: 4, width: W - lx - 28, height: 14); lbl.lineBreakMode = .byTruncatingTail
            cell.addSubview(lbl)
            if active {
                let dot = NSTextField(labelWithString: "●")
                dot.font = .systemFont(ofSize: 8); dot.textColor = .controlAccentColor
                dot.frame = NSRect(x: W - 24, y: 5, width: 10, height: 12); cell.addSubview(dot)
            }
        case .folderHeader(let name, _, let collapsed):
            // A colored folder (blue, like Finder) — filled when open, outline when collapsed.
            let fi = NSImageView(frame: NSRect(x: 14, y: 6, width: 22, height: 20))
            fi.image = NSImage(systemSymbolName: collapsed ? "folder" : "folder.fill",
                               accessibilityDescription: "folder")?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
            fi.contentTintColor = NSColor(srgbRed: 0.94, green: 0.71, blue: 0.33, alpha: 1)  // warm amber
            fi.imageScaling = .scaleProportionallyDown; cell.addSubview(fi)
            let lbl = NSTextField(labelWithString: name)
            lbl.font = .systemFont(ofSize: 14, weight: .semibold); lbl.textColor = .labelColor
            lbl.frame = NSRect(x: 44, y: 7, width: W - 60, height: 18); lbl.lineBreakMode = .byTruncatingTail
            cell.addSubview(lbl)
        case .splitHeader(let title, _, let count, let collapsed):
            let chev = NSImageView(frame: NSRect(x: 20, y: 4, width: 10, height: 12))
            chev.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                 accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            chev.contentTintColor = .tertiaryLabelColor; chev.imageScaling = .scaleProportionallyDown
            cell.addSubview(chev)
            let fi = NSImageView(frame: NSRect(x: 34, y: 4, width: 15, height: 13))
            fi.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "split")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            fi.contentTintColor = .secondaryLabelColor; fi.imageScaling = .scaleProportionallyDown
            cell.addSubview(fi)
            let text = title.isEmpty ? "Split (\(count))" : "\(title)  ·  split (\(count))"
            let lbl = NSTextField(labelWithString: text)
            lbl.font = .systemFont(ofSize: 11, weight: .medium); lbl.textColor = .secondaryLabelColor
            lbl.frame = NSRect(x: 56, y: 4, width: W - 72, height: 14); lbl.lineBreakMode = .byTruncatingTail
            cell.addSubview(lbl)
        case .rule:
            let line = NSView(frame: NSRect(x: 16, y: 6, width: W - 32, height: 1))
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            cell.addSubview(line)
        case .newTab:
            cell.addSubview(plusRow(glyph: "plus", text: "New tab", hint: "⌘-click: private"))
        case .context(let label, let apps, let id, let ai):
            // Always the same calm leading glyph (fixed x so the text column aligns with app rows).
            let gi = NSImageView(frame: NSRect(x: 13, y: 12, width: 28, height: 26))
            gi.image = contextGlyph
            gi.contentTintColor = contextColor(for: id)      // per-context color (default warm amber)
            gi.imageScaling = .scaleProportionallyDown; gi.toolTip = "Context"
            cell.addSubview(gi)
            let tx: CGFloat = 52
            let aiW: CGFloat = ai ? 24 : 0                 // room for the trailing AI badge
            let title = NSTextField(labelWithString: label)
            title.font = .systemFont(ofSize: 14, weight: .semibold); title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingTail
            title.sizeToFit()                              // natural width incl. text insets → no early ellipsis
            let titleW = min(title.frame.width, (W - 16) - tx - aiW)
            title.frame = NSRect(x: tx, y: 28, width: titleW, height: 18)
            title.toolTip = label; cell.addSubview(title)
            if ai {
                let ax = NSImageView(frame: NSRect(x: tx + titleW + 5, y: 29, width: 16, height: 16))
                ax.image = aiGlyph; ax.contentTintColor = .tertiaryLabelColor       // gray, like the pin
                ax.imageScaling = .scaleProportionallyDown
                ax.toolTip = "Named on-device by Apple Intelligence"; cell.addSubview(ax)
            }
            let sub = NSTextField(labelWithString: apps.joined(separator: " · "))
            sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
            sub.frame = NSRect(x: tx, y: 9, width: (W - 16) - tx, height: 15); sub.lineBreakMode = .byTruncatingTail
            cell.addSubview(sub)
        case .newContext:
            cell.addSubview(plusRow(glyph: "plus", text: "New context", hint: nil))
        case .addTabs:
            cell.addSubview(plusRow(glyph: "plus", text: "Add tabs", hint: nil))
        case .pickDone:
            let lbl = NSTextField(labelWithString: "‹  Done")
            lbl.font = .systemFont(ofSize: 12, weight: .medium); lbl.textColor = .secondaryLabelColor
            lbl.frame = NSRect(x: 14, y: 4, width: W - 28, height: 16); cell.addSubview(lbl)
        case .pickItem(let ref, let on):
            // checkbox + favicon/icon + title; whole row toggles membership.
            let box = NSImageView(frame: NSRect(x: 16, y: 11, width: 18, height: 18))
            box.image = NSImage(systemSymbolName: on ? "checkmark.circle.fill" : "circle",
                                accessibilityDescription: on ? "in context" : "not in context")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            box.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
            box.imageScaling = .scaleProportionallyDown; cell.addSubview(box)
            let iv = NSImageView(frame: NSRect(x: 42, y: 11, width: 18, height: 18))
            iv.imageScaling = .scaleProportionallyUpOrDown; cell.addSubview(iv)
            if let domain = FaviconLoader.domain(of: ref.url) {
                if let fav = FaviconLoader.shared.cached(domain) { iv.image = fav }
                else { iv.image = icon(for: ref.app); FaviconLoader.shared.load(domain, from: ref.url) { [weak iv] img in iv?.image = img } }
            } else { iv.image = icon(for: ref.app) }
            let title = NSTextField(labelWithString: ref.title)
            title.font = titleFont; title.textColor = on ? .labelColor : .secondaryLabelColor
            title.frame = NSRect(x: 68, y: 11, width: W - 84, height: 18); title.lineBreakMode = .byTruncatingTail
            title.toolTip = ref.title; cell.addSubview(title)
        case .contextHeader(let id, let label):
            // identity + inline rename: amber stack glyph, then an editable name field.
            let gi = NSImageView(frame: NSRect(x: 14, y: 7, width: 26, height: 24))
            gi.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "context")?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
            gi.contentTintColor = contextColor(for: id)      // per-context color (default warm amber)
            gi.imageScaling = .scaleProportionallyDown; cell.addSubview(gi)
            let field = RenameField(string: label)
            field.font = .systemFont(ofSize: 15, weight: .semibold); field.textColor = .labelColor
            field.frame = NSRect(x: 48, y: 9, width: W - 92, height: 22)
            field.toolTip = "Click to rename"
            field.onCommit = { [weak self] new in self?.renameContext(id, to: new) }
            cell.addSubview(field)
            let pencil = NSImageView(frame: NSRect(x: W - 36, y: 11, width: 16, height: 16))
            pencil.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "rename")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            pencil.contentTintColor = .tertiaryLabelColor; pencil.imageScaling = .scaleProportionallyDown
            pencil.toolTip = "Click the name to rename"; cell.addSubview(pencil)
        case .tab(let ref):
            let closable = ref.close != nil
            let host: NSView = closable ? TabCell() : cell      // closable rows get a hover-× container
            // Flat inside a context (no folder/split tree); keep the nesting only in the app's own tab view.
            let flat: Bool = { if case .context = mode { return true }; return false }()
            let indent: CGFloat = flat ? 0 : (ref.folder != nil ? 20 : 0) + (ref.splitId != nil ? 16 : 0)  // folder + split nesting
            let iv = NSImageView(frame: NSRect(x: 16 + indent, y: 11, width: 18, height: 18))
            iv.imageScaling = .scaleProportionallyUpOrDown; host.addSubview(iv)
            if let avatar = ref.leadImage {                                // contact photo → circular avatar
                iv.image = avatar
                iv.wantsLayer = true; iv.layer?.cornerRadius = 9; iv.layer?.masksToBounds = true
            } else if let domain = FaviconLoader.domain(of: ref.url) {
                if let fav = FaviconLoader.shared.cached(domain) { iv.image = fav }
                else { iv.image = icon(for: ref.app)                       // placeholder until favicon loads
                       FaviconLoader.shared.load(domain, from: ref.url) { [weak iv] img in iv?.image = img } }
            } else { iv.image = icon(for: ref.app) }
            let reserve: CGFloat = (closable ? 30 : 0) + (ref.incognito ? 22 : 0)   // room for × / glyph
            let hasSub = (ref.subtitle?.isEmpty == false)   // only plugin items (e.g. VS Code folder) set this
            let titleFrame = NSRect(x: 42 + indent, y: hasSub ? 20 : 11, width: W - 58 - indent - reserve, height: 18)
            addMatchChips(to: host, text: ref.title, titleFrame: titleFrame)   // pill behind matches
            let title = NSTextField(labelWithString: ref.title)
            title.font = titleFont; title.textColor = .labelColor
            title.frame = titleFrame; title.lineBreakMode = .byTruncatingTail
            title.toolTip = ref.title                      // full title on hover (no marquee)
            host.addSubview(title)
            if let sub = ref.subtitle, !sub.isEmpty {      // secondary line (VS Code's folder) — stacked under the title
                let s = NSTextField(labelWithString: sub)
                s.font = .systemFont(ofSize: 11); s.textColor = .secondaryLabelColor
                s.frame = NSRect(x: 42 + indent, y: 5, width: W - 58 - indent - reserve, height: 14)
                s.lineBreakMode = .byTruncatingHead; s.toolTip = sub    // truncate the FRONT so the deepest folder stays visible
                host.addSubview(s)
            }
            if r == activeRowIndex {   // exactly one dot: the currently-open tab. Sits between the selection pill's left edge (x6) and the icon (x16), so the hover pill doesn't crowd it.
                let dot = NSView(frame: NSRect(x: 8, y: 18, width: 5, height: 5))
                dot.wantsLayer = true; dot.layer?.cornerRadius = 2.5
                dot.layer?.backgroundColor = NSColor(srgbRed: 1.0, green: 179/255.0, blue: 0, alpha: 1).cgColor   // #FFB300 — brighter, more obvious amber (still the live-status family, not blue)
                dot.toolTip = "Currently open"; host.addSubview(dot)
            }
            if ref.incognito {                            // private/incognito → subtle trailing glyph
                let gx: CGFloat = closable ? W - 60 : W - 30   // sit left of the × when both present
                let gi = NSImageView(frame: NSRect(x: gx, y: 12, width: 16, height: 16))
                gi.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "private")?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
                gi.contentTintColor = .secondaryLabelColor; gi.imageScaling = .scaleProportionallyDown
                gi.toolTip = "Incognito"; host.addSubview(gi)
            }
            if let tc = host as? TabCell {
                tc.closeBtn.frame = NSRect(x: W - 40, y: 11, width: 18, height: 18)   // off the right edge; room for the hover-grow
                tc.onClose = { [weak self] in self?.closeTab(ref) }
                return tc
            }
        }
        return cell
    }
}
