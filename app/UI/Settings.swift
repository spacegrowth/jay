import AppKit
import ServiceManagement
import ApplicationServices
import Contacts
import CoreServices     // AEDeterminePermissionToAutomateTarget — query per-app Automation status

/// Preferences window that opts out of AppKit's automatic frame-constraining. Otherwise every
/// `setContentSize`/`setFrame` (including while the window is briefly off-screen during setup, or
/// near a monitor's top edge) gets molested by `constrainFrameRect` — which shrank the content to
/// just the title bar and walked the window up the screen. We clamp placement onto the visible
/// frame ourselves, so disabling the OS pass is safe.
final class PrefsWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A two-handle range slider (0–100) — the band is the filled segment between the
/// handles. More obvious than two separate sliders for picking a top/bottom range.
final class RangeSlider: NSView {
    var low: CGFloat = 3 { didSet { needsDisplay = true } }
    var high: CGFloat = 55 { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var onChange: ((CGFloat, CGFloat) -> Void)?
    private var drag = 0
    private let r: CGFloat = 7
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    private func px(_ v: CGFloat) -> CGFloat { r + (bounds.width - 2 * r) * (v / 100) }
    private func val(_ x: CGFloat) -> CGFloat { max(0, min(100, (x - r) / (bounds.width - 2 * r) * 100)) }

    override func draw(_ dirty: NSRect) {
        let y = bounds.midY, a: CGFloat = enabled ? 1 : 0.4
        let track = NSBezierPath(); track.lineWidth = 3; track.lineCapStyle = .round
        track.move(to: NSPoint(x: px(0), y: y)); track.line(to: NSPoint(x: px(100), y: y))
        NSColor.tertiaryLabelColor.withAlphaComponent(a).setStroke(); track.stroke()
        let fill = NSBezierPath(); fill.lineWidth = 3; fill.lineCapStyle = .round
        fill.move(to: NSPoint(x: px(low), y: y)); fill.line(to: NSPoint(x: px(high), y: y))
        NSColor.controlAccentColor.withAlphaComponent(a).setStroke(); fill.stroke()
        for v in [low, high] {
            let h = NSBezierPath(ovalIn: NSRect(x: px(v) - r, y: y - r, width: r * 2, height: r * 2))
            NSColor.white.withAlphaComponent(a).setFill(); h.fill()
            NSColor.tertiaryLabelColor.setStroke(); h.lineWidth = 1; h.stroke()
        }
    }
    override func mouseDown(with e: NSEvent) {
        guard enabled else { return }
        let p = convert(e.locationInWindow, from: nil)
        drag = abs(p.x - px(low)) <= abs(p.x - px(high)) ? 1 : 2
        mouseDragged(with: e)
    }
    override func mouseDragged(with e: NSEvent) {
        guard enabled else { return }
        let v = val(convert(e.locationInWindow, from: nil).x)
        if drag == 1 { low = min(v, high - 5) } else { high = max(v, low + 5) }
        onChange?(low, high)
    }
}

/// A button that records a key combo: click it, then press the shortcut. Captures
/// key-down (incl. ⌘-combos via performKeyEquivalent) and reports code/mods/label.
final class RecorderButton: NSButton {
    var onCapture: ((Int, Int, String) -> Void)?
    var currentLabel = "Click, then press your shortcut" { didSet { if !recording { title = currentLabel } } }
    private var recording = false {
        didSet { title = recording ? "Press your shortcut…" : currentLabel }
    }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with e: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if recording { capture(e); return true }
        return super.performKeyEquivalent(with: e)
    }
    override func keyDown(with e: NSEvent) {
        if recording { capture(e) } else { super.keyDown(with: e) }
    }
    private func capture(_ e: NSEvent) {
        let code = Int(e.keyCode)
        let mods = Hotkey.mods(e.modifierFlags)
        if code == 53 && mods == 0 { recording = false; window?.makeFirstResponder(nil); return }  // bare Esc = cancel
        guard Hotkey.acceptable(code: code, mods: mods) else { return }   // need a modifier or a named key
        recording = false
        window?.makeFirstResponder(nil)
        onCapture?(code, mods, Hotkey.label(code: code, mods: mods, chars: e.charactersIgnoringModifiers))
    }
}

/// A regular macOS-style Settings window (opaque, system-themed, self-sizing) to
/// configure the summon shortcut, with an About section. Radio rows write live to
/// UserDefaults "triggerKey"; choosing a ⌘ option reveals a Siri-conflict note and
/// the window grows to fit it.
final class SettingsPanel: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var generalVC: NSViewController!     // shortcut/edge/startup — resizes on note/recorder reveal
    private var permsVC: NSViewController!        // permissions — resizes when the access button hides
    private let pluginsVC = NSViewController()    // installed-plugins list (rebuilt on show / toggle / test)
    private let pluginsBody = NSStackView()       // the plugins pane's content stack, repopulated live
    private let triggerPopup = NSPopUpButton()
    private let recorder = RecorderButton()
    private let customTitle = "Custom shortcut…"
    private let note = NSTextField(wrappingLabelWithString: "")
    private let loginToggle = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let menuIconToggle = NSButton(checkboxWithTitle: "Show menu bar icon", target: nil, action: nil)
    private let autoUpdateToggle = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let autoInstallToggle = NSButton(checkboxWithTitle: "Install updates in the background", target: nil, action: nil)
    private let edgeToggle = NSButton(checkboxWithTitle: "Summon at left screen edge", target: nil, action: nil)
    private let contextsToggle = NSButton(checkboxWithTitle: "Show Contexts", target: nil, action: nil)
    private let aiLabelToggle = NSButton(checkboxWithTitle: "Name contexts with on-device AI", target: nil, action: nil)
    private let faviconToggle = NSButton(checkboxWithTitle: "Fetch site icons from the network", target: nil, action: nil)
    private let edgeRange = RangeSlider()
    private let edgeBandLabel = NSTextField(labelWithString: "")
    private let accessDot = NSImageView()
    private let accessLabel = NSTextField(labelWithString: "")
    private let accessButton = NSButton()
    private var accessTimer: Timer?
    // Contacts + per-app Automation status (all polled while Preferences is open).
    private let contactsDot = NSImageView()
    private let contactsLabel = NSTextField(labelWithString: "")
    private let contactsButton = NSButton()
    private let scriptableApps = ["Safari", "Arc", "Google Chrome", "iTerm2", "Spotify", "Music", "Messages"]
    private var autoDots: [String: NSImageView] = [:]
    private var autoStatusLabels: [String: NSTextField] = [:]
    // Content column geometry (window width = contentW + 2·pad).
    private let contentW: CGFloat = 360
    private let pad: CGFloat = 20

    override init() {
        window = PrefsWindow(contentRect: NSRect(x: 0, y: 0, width: 573, height: 220),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        super.init()
        window.title = "Jay Preferences"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false        // stay open when you click away to test a setting
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor   // paint the content area (no see-through desktop)
        window.isRestorable = false      // don't let AppKit restore a stale (collapsed) saved frame
        window.delegate = self
        build()
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 11, weight: .semibold); l.textColor = .secondaryLabelColor
        return l
    }

    /// A grouped settings "card": rounded, subtly-filled box around a vertical run of controls.
    /// Inner stack fills width so popups/buttons/sliders span the card and labels wrap cleanly.
    private func card(_ rows: [NSView], spacing: CGFloat = 9) -> NSView {
        let inner = NSStackView(views: rows)
        inner.orientation = .vertical; inner.alignment = .width; inner.spacing = spacing
        inner.distribution = .fill
        inner.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.cornerRadius = 9
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.addSubview(inner)
        let p: CGFloat = 14
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: p),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -p),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: p),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -p),
        ])
        return box
    }

    /// A secondary, wrapping explanatory line sized to sit under a control inside a card.
    private func detail(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = contentW - 28    // card pad (14×2)
        return l
    }

    private func build() {
        // — Summon shortcut —
        triggerPopup.target = self; triggerPopup.action = #selector(pickTrigger(_:))
        for key in TriggerKey.allCases { triggerPopup.addItem(withTitle: key.label) }
        triggerPopup.menu?.addItem(.separator())
        triggerPopup.addItem(withTitle: customTitle)
        selectCurrentTrigger()

        recorder.bezelStyle = .rounded; recorder.font = .systemFont(ofSize: 13)
        recorder.currentLabel = UserDefaults.standard.string(forKey: "hotkeyLabel") ?? "Click, then press your shortcut"
        recorder.onCapture = { [weak self] code, mods, label in
            let d = UserDefaults.standard
            d.set(code, forKey: "hotkeyCode"); d.set(mods, forKey: "hotkeyMods"); d.set(label, forKey: "hotkeyLabel")
            d.set("custom", forKey: "triggerKey")
            self?.recorder.currentLabel = label
        }

        note.font = .systemFont(ofSize: 11); note.textColor = .systemOrange
        note.preferredMaxLayoutWidth = contentW - 28
        let shortcutDetail = detail("Pick a ready-made trigger, or record your own combo.")

        // — Screen edge —
        edgeToggle.font = .systemFont(ofSize: 13)
        edgeToggle.target = self; edgeToggle.action = #selector(toggleEdge(_:))
        edgeToggle.state = UserDefaults.standard.bool(forKey: "edgeTrigger") ? .on : .off
        edgeRange.low = UserDefaults.standard.double(forKey: "edgeBandTop")
        edgeRange.high = UserDefaults.standard.double(forKey: "edgeBandBottom")
        edgeRange.onChange = { [weak self] lo, hi in
            UserDefaults.standard.set(lo, forKey: "edgeBandTop")
            UserDefaults.standard.set(hi, forKey: "edgeBandBottom")
            self?.updateEdgeLabel()
        }
        edgeRange.heightAnchor.constraint(equalToConstant: 18).isActive = true
        edgeBandLabel.font = .systemFont(ofSize: 11); edgeBandLabel.textColor = .secondaryLabelColor
        let edgeDetail = detail("Push the pointer into the screen edge to summon. Drag the handles to limit where along the edge it triggers.")

        // — Startup —
        loginToggle.font = .systemFont(ofSize: 13)
        loginToggle.target = self; loginToggle.action = #selector(toggleLogin(_:))
        loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        menuIconToggle.font = .systemFont(ofSize: 13)
        menuIconToggle.target = self; menuIconToggle.action = #selector(toggleMenuIcon(_:))
        menuIconToggle.state = UserDefaults.standard.bool(forKey: "showMenuIcon") ? .on : .off
        menuIconToggle.toolTip = "If hidden, summon with your shortcut, then open Preferences from the panel's gear."

        autoUpdateToggle.font = .systemFont(ofSize: 13)
        autoUpdateToggle.target = self; autoUpdateToggle.action = #selector(toggleAutoUpdate(_:))
        autoUpdateToggle.state = updater.automaticallyChecksForUpdates ? .on : .off
        autoInstallToggle.state = updater.automaticallyDownloadsUpdates ? .on : .off

        // Off (default): when an update is found, Sparkle shows "Install and Relaunch" — one click
        // installs it and restarts into the new version. On: silent background install applied on
        // next quit (no relaunch prompt). Off is the default so updates are visible + one-click.
        autoInstallToggle.font = .systemFont(ofSize: 13)
        autoInstallToggle.target = self; autoInstallToggle.action = #selector(toggleAutoInstall(_:))
        autoInstallToggle.state = updater.automaticallyDownloadsUpdates ? .on : .off
        autoInstallToggle.toolTip = "Off: you get a one-click “Install and Relaunch”. On: updates install quietly and apply when you next quit Jay."

        // — Contexts —
        contextsToggle.title = "Show Contexts"
        contextsToggle.font = .systemFont(ofSize: 13)
        contextsToggle.target = self; contextsToggle.action = #selector(toggleContexts(_:))
        contextsToggle.state = UserDefaults.standard.bool(forKey: "showContexts") ? .on : .off
        let contextsNote = detail("Tabs, sessions and windows that belong to the same task are grouped at the top — a repo, a project, a site. Grouped on-device; your renames are kept.")

        // On-device AI naming is opt-in (off by default). When on, Apple's on-device model
        // (FoundationModels, macOS 26) proposes context names — fully local, nothing leaves the Mac.
        aiLabelToggle.font = .systemFont(ofSize: 13)
        aiLabelToggle.target = self; aiLabelToggle.action = #selector(toggleAILabel(_:))
        aiLabelToggle.state = UserDefaults.standard.bool(forKey: "ctxAILabeling") ? .on : .off
        aiLabelToggle.toolTip = "Off: contexts use plain derived names. On: the on-device model names them (local only)."
        let aiLabelNote = detail("Uses Apple's on-device model to suggest context names. Fully local — nothing leaves your Mac. Requires Apple Intelligence (macOS 26+).")


        // — Favicons —
        faviconToggle.font = .systemFont(ofSize: 13)
        faviconToggle.target = self; faviconToggle.action = #selector(toggleFavicon(_:))
        faviconToggle.state = UserDefaults.standard.bool(forKey: "faviconLookup") ? .on : .off
        let faviconNote = detail("Look up each site's icon from DuckDuckGo and Google (falling back to the site itself). Off → no icons are fetched and the app makes no network calls at all; icons already cached on disk still show.")

        // — Permissions —
        // Accessibility
        accessDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        accessDot.imageScaling = .scaleProportionallyDown
        accessLabel.font = .systemFont(ofSize: 13)
        let permRow = NSStackView(views: [accessDot, accessLabel])
        permRow.orientation = .horizontal; permRow.spacing = 7; permRow.alignment = .centerY
        accessDot.widthAnchor.constraint(equalToConstant: 11).isActive = true
        let permDetail = detail("Powers the summon shortcut and switching to app windows. Off → the hotkey won’t fire and window switching won’t work.")
        accessButton.title = "Open Accessibility Settings…"
        accessButton.bezelStyle = .rounded
        accessButton.target = self; accessButton.action = #selector(openAccess)

        // Contacts
        contactsDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        contactsDot.imageScaling = .scaleProportionallyDown
        contactsDot.widthAnchor.constraint(equalToConstant: 11).isActive = true
        contactsLabel.font = .systemFont(ofSize: 13)
        let contactsRow = NSStackView(views: [contactsDot, contactsLabel])
        contactsRow.orientation = .horizontal; contactsRow.spacing = 7; contactsRow.alignment = .centerY
        let contactsDetail = detail("Puts names and photos on recent Messages. Off → Messages shows raw phone numbers.")
        contactsButton.bezelStyle = .rounded
        contactsButton.target = self; contactsButton.action = #selector(contactsAction)

        // Automation — one status row per scriptable app we read from
        let autoDetail = detail("Lets the app read tabs, tracks and messages and switch to them — asked per app the first time it’s used. Off → that app’s items won’t appear.")
        var autoRows: [NSView] = [autoDetail]
        for name in scriptableApps {
            let dot = NSImageView()
            dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            dot.imageScaling = .scaleProportionallyDown
            dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
            let nm = NSTextField(labelWithString: name); nm.font = .systemFont(ofSize: 13)
            let st = NSTextField(labelWithString: "")
            st.font = .systemFont(ofSize: 12); st.textColor = .secondaryLabelColor; st.alignment = .right
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [dot, nm, spacer, st])
            row.orientation = .horizontal; row.spacing = 7; row.alignment = .centerY
            autoDots[name] = dot; autoStatusLabels[name] = st
            autoRows.append(row)
        }
        let autoButton = NSButton(title: "Open Automation Settings…", target: self, action: #selector(openAutomation))
        autoButton.bezelStyle = .rounded
        autoRows.append(autoButton)

        // — About —
        let name = NSTextField(labelWithString: "Jay")
        name.font = .systemFont(ofSize: 13, weight: .semibold); name.textColor = .labelColor
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let version = NSTextField(labelWithString: "Version \(v)")
        version.font = .systemFont(ofSize: 12); version.textColor = .secondaryLabelColor
        let blurb = detail("Summon a list of tabs, sessions and windows across every app, and jump to any of them.")
        let quit = NSButton(title: "Quit Jay", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded

        // Native toolbar tabs. NSTabViewController sizes the window to each pane's own content,
        // so panes can't hit the content-view fitting-size bug a hand-rolled split layout did.
        generalVC = makePaneVC([
            ("Summon shortcut", card([triggerPopup, recorder, note, shortcutDetail])),
            ("Screen edge",     card([edgeToggle, edgeRange, edgeBandLabel, edgeDetail])),
            ("Startup",         card([loginToggle, menuIconToggle, autoUpdateToggle, autoInstallToggle])),
            ("Site icons",      card([faviconToggle, faviconNote])),
        ])
        let contextsVC = makePaneVC([
            ("Contexts", card([contextsToggle, contextsNote])),
            ("Naming",   card([aiLabelToggle, aiLabelNote])),
        ])
        permsVC = makePaneVC([
            ("Accessibility", card([permRow, permDetail, accessButton])),
            ("Contacts",      card([contactsRow, contactsDetail, contactsButton])),
            ("Automation",    card(autoRows)),
        ])
        let aboutVC = makePaneVC([
            ("About", card([name, version, blurb, quit])),
        ])
        buildPluginsPane()                            // dynamic list, populated by refreshPluginsPane()

        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar
        for (label, symbol, vc) in [
            ("General",     "gearshape",             generalVC!),
            ("Contexts",    "square.grid.2x2",       contextsVC),
            ("Plugins",     "puzzlepiece.extension", pluginsVC),
            ("Permissions", "lock.shield",           permsVC!),
            ("About",       "info.circle",           aboutVC),
        ] {
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabVC.addTabViewItem(item)
        }
        window.contentViewController = tabVC
        syncNote(); syncEdge(); refreshPluginsPane()
    }

    // MARK: Plugins tab

    /// Set up the plugins pane's fixed frame; `refreshPluginsPane` fills `pluginsBody` with the
    /// live list each time Preferences opens or a plugin is toggled/tested.
    private func buildPluginsPane() {
        pluginsBody.orientation = .vertical; pluginsBody.alignment = .width; pluginsBody.spacing = 16
        pluginsBody.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(pluginsBody)
        NSLayoutConstraint.activate([
            pluginsBody.centerXAnchor.constraint(equalTo: root.centerXAnchor),   // center the column (window is wider than it, due to the toolbar)
            pluginsBody.widthAnchor.constraint(equalToConstant: contentW),
            pluginsBody.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            pluginsBody.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: contentW + pad * 2),
        ])
        pluginsVC.view = root
    }

    /// Rebuild the plugins list from PluginHost.statuses(): one row per plugin (status dot, name →
    /// target, latency, Test, enable switch), then the plugins-folder actions. Resizes the pane.
    private func refreshPluginsPane() {
        pluginsBody.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let head = sectionLabel("Installed plugins")
        pluginsBody.addArrangedSubview(head)
        let statuses = PluginHost.statuses()
        if statuses.isEmpty {
            pluginsBody.addArrangedSubview(card([detail("No plugins installed. Drop a plugin folder into the folder below, then Rescan.")]))
        } else {
            pluginsBody.addArrangedSubview(card(statuses.map { pluginRow($0) }, spacing: 12))
        }
        pluginsBody.setCustomSpacing(7, after: head)

        let head2 = sectionLabel("Plugins folder")
        pluginsBody.addArrangedSubview(head2)
        let path = detail(PluginHost.root.path)
        let add = NSButton(title: "Add plugin…", target: self, action: #selector(addPlugin)); add.bezelStyle = .rounded
        add.toolTip = "Point Jay at a plugin folder anywhere on your Mac — it's loaded in place, not copied"
        let docs = NSButton(title: "Write a plugin →", target: self, action: #selector(openPluginDocs)); docs.bezelStyle = .rounded
        docs.toolTip = "Open the plugin docs (manifest + list/activate/close) and a copyable example"
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealPluginsFolder)); reveal.bezelStyle = .rounded
        let rescan = NSButton(title: "Rescan", target: self, action: #selector(rescanPlugins)); rescan.bezelStyle = .rounded
        let row1 = NSStackView(views: [add, docs]);     row1.orientation = .horizontal; row1.spacing = 8; row1.alignment = .centerY
        let row2 = NSStackView(views: [reveal, rescan]); row2.orientation = .horizontal; row2.spacing = 8; row2.alignment = .centerY
        pluginsBody.addArrangedSubview(card([path, row1, row2]))
        pluginsBody.setCustomSpacing(7, after: head2)

        refit(pluginsVC)
    }

    /// One plugin row. Carries the plugin id in the control identifiers so the actions know which.
    private func pluginRow(_ s: PluginStatus) -> NSView {
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.imageScaling = .scaleProportionallyDown
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let color: NSColor, statusText: String
        if !s.enabled                       { color = .tertiaryLabelColor; statusText = "Disabled" }
        else if s.lastMs == nil             { color = .tertiaryLabelColor; statusText = "not run yet" }
        else if let ms = s.lastMs, ms < 0   { color = .systemOrange;       statusText = "timed out" }
        else if let ms = s.lastMs, ms > 200 { color = .systemOrange;       statusText = "\(Int(ms)) ms (slow)" }
        else                                { color = .systemGreen;        statusText = "\(Int(s.lastMs ?? 0)) ms" }
        dot.contentTintColor = color

        let name = NSTextField(labelWithString: s.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let srcTag: String? = s.source == .builtIn ? "Built-in" : (s.source == .added ? "Added" : nil)
        let subText = [srcTag, s.targetApp.map { "→ \($0)" }, statusText].compactMap { $0 }.joined(separator: "   ")
        let sub = NSTextField(labelWithString: subText)
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        let namecol = NSStackView(views: [name, sub]); namecol.orientation = .vertical; namecol.alignment = .leading; namecol.spacing = 1
        namecol.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let test = NSButton(title: "Test", target: self, action: #selector(testPlugin(_:)))
        test.bezelStyle = .rounded; test.controlSize = .small; test.font = .systemFont(ofSize: 11)
        test.identifier = NSUserInterfaceItemIdentifier(s.id)
        test.toolTip = "Run this plugin now and measure how fast it responds"
        test.widthAnchor.constraint(equalToConstant: 74).isActive = true   // fixed so the "Testing…"/result text doesn't jump the row

        let sw = NSSwitch()
        sw.state = s.enabled ? .on : .off
        sw.target = self; sw.action = #selector(togglePlugin(_:))
        sw.identifier = NSUserInterfaceItemIdentifier(s.id)

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)   // takes the slack → dot+name pinned left, controls pinned right (consistent across rows)
        var views: [NSView] = [dot, namecol, spacer]
        if s.source == .added {                                    // added plugins can be forgotten (never deletes files)
            let remove = NSButton(); remove.isBordered = false
            remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")
            remove.contentTintColor = .secondaryLabelColor
            remove.target = self; remove.action = #selector(removePlugin(_:))
            remove.identifier = NSUserInterfaceItemIdentifier(s.id)
            remove.toolTip = "Remove this added plugin (doesn't delete your files)"
            views.append(remove)
        }
        views += [test, sw]
        let row = NSStackView(views: views)
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        return row
    }

    @objc private func togglePlugin(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        PluginHost.setEnabled(id, on)     // opt-in: switch on → enabled
        if on, let plugin = PluginHost.discoverAll().first(where: { $0.id == id }) {
            let installed = PluginHost.installEditorExtensions(for: plugin)
            if !installed.isEmpty {
                let a = NSAlert()
                a.messageText = "Jay Bridge installed"
                a.informativeText = "Installed the Jay Bridge extension into \(installed.joined(separator: ", ")). Reload (⌘⇧P → Developer: Reload Window) to finish."
                a.runModal()
            }
        }
        refreshPluginsPane()
    }
    @objc private func testPlugin(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.title = "Testing…"; sender.isEnabled = false     // immediate feedback that the click registered
        DispatchQueue.global(qos: .userInitiated).async {
            let r = PluginHost.probe(id: id)                    // runs the plugin's `list`, times it (may block up to 2s)
            DispatchQueue.main.async {
                sender.isEnabled = true
                sender.title = r.map { $0.ms < 0 ? "Failed" : "✓ \(Int($0.ms)) ms" } ?? "Failed"   // flash the result
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.refreshPluginsPane() }
            }
        }
    }
    @objc private func revealPluginsFolder() {
        try? FileManager.default.createDirectory(at: PluginHost.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([PluginHost.root])
    }
    @objc private func rescanPlugins() { refreshPluginsPane() }

    /// Point Jay at a plugin folder anywhere on disk (loaded in place, not copied).
    @objc private func addPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Add Plugin"
        panel.message = "Choose a plugin folder — it must contain a plugin.json and its executable."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if PluginHost.addExternalPlugin(url) {
            refreshPluginsPane()
        } else {
            let a = NSAlert()
            a.messageText = "That folder isn't a valid plugin"
            a.informativeText = "It needs a plugin.json (apiVersion 1) and an executable named by its \"exec\" field."
            a.runModal()
        }
    }

    /// Forget an added plugin — removes the reference only, never the user's files.
    @objc private func removePlugin(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        PluginHost.removeExternalPlugin(id: id)
        refreshPluginsPane()
    }

    @objc private func openPluginDocs() {
        if let url = URL(string: "https://github.com/spacegrowth/jay/blob/main/plugins/README.md") {
            NSWorkspace.shared.open(url)
        }
    }

    /// One tab's content: a fixed-width column of (header + card) groups inside a view controller.
    /// The width constraint makes the view's fittingSize reliable, so NSTabViewController can size
    /// the window to it. preferredContentSize is what the tab controller resizes the window to.
    private func makePaneVC(_ groups: [(String, NSView)]) -> NSViewController {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (title, box) in groups {
            let lbl = sectionLabel(title)
            stack.addArrangedSubview(lbl)
            stack.addArrangedSubview(box)
            stack.setCustomSpacing(7, after: lbl)        // header hugs its card
        }
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            // Center the fixed-width content column so it isn't shoved to one side when the toolbar
            // makes the window wider than the column.
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: contentW),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: contentW + pad * 2),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }

    /// Re-measure a pane and let the tab controller resize the window to it (used after a control
    /// inside the pane shows/hides — the custom-shortcut recorder, the Siri note, the access button).
    private func refit(_ vc: NSViewController?) {
        guard let vc = vc else { return }
        vc.view.layoutSubtreeIfNeeded()
        vc.preferredContentSize = vc.view.fittingSize
    }

    private var isCustomTrigger: Bool { UserDefaults.standard.string(forKey: "triggerKey") == "custom" }

    /// Show the Siri note only for a Command double-tap; show the recorder only for Custom.
    private func syncNote() {
        let raw = UserDefaults.standard.string(forKey: "triggerKey") ?? "leftOpt"
        if raw == "leftCmd" || raw == "rightCmd" {
            note.isHidden = false
            note.stringValue = "Tip: macOS may use a Command double-tap for Siri or Dictation — turn that off in System Settings ▸ Keyboard if it conflicts."
        } else if isCustomTrigger {
            note.isHidden = false
            note.stringValue = "Note: a custom shortcut still reaches the app you're in (it isn't swallowed) — pick a combo that's free in your apps."
        } else {
            note.isHidden = true
        }
        recorder.isHidden = !isCustomTrigger
        refit(generalVC)
    }

    /// Reflect live Accessibility status: green when granted (and hide the button). Only resizes
    /// the window when the status actually flips — the 1s poll must NOT resize every tick (each
    /// resize re-runs constrainFrameRect and walks the window up the screen).
    private func updatePermissions() { updateAccess(); updateContacts(); updateAutomation() }

    private func updateAccess() {
        let ok = AXIsProcessTrusted()
        accessDot.contentTintColor = ok ? .systemGreen : .systemOrange
        accessLabel.stringValue = ok ? "Accessibility access granted" : "Accessibility access needed"
        accessLabel.textColor = .labelColor
        accessButton.isHidden = ok
        if lastAccessOK != ok { lastAccessOK = ok; refit(permsVC) }
    }
    private var lastAccessOK: Bool?

    private func updateContacts() {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            contactsDot.contentTintColor = .systemGreen; contactsLabel.stringValue = "Contacts access granted"
            contactsButton.title = "Open Contacts Settings…"
        case .denied, .restricted:
            contactsDot.contentTintColor = .systemOrange; contactsLabel.stringValue = "Contacts access denied"
            contactsButton.title = "Open Contacts Settings…"
        default:
            contactsDot.contentTintColor = .systemGray; contactsLabel.stringValue = "Contacts access not requested"
            contactsButton.title = "Enable Contacts Access"
        }
    }

    private func updateAutomation() {
        for name in scriptableApps {
            guard let dot = autoDots[name], let st = autoStatusLabels[name] else { continue }
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
                  let bid = app.bundleIdentifier else {
                dot.contentTintColor = .systemGray; st.stringValue = "Not running"; continue
            }
            switch Self.automationStatus(bid) {
            case noErr:
                dot.contentTintColor = .systemGreen; st.stringValue = "Allowed"
            case OSStatus(errAEEventNotPermitted):
                dot.contentTintColor = .systemOrange; st.stringValue = "Denied"
            default:
                dot.contentTintColor = .systemGray; st.stringValue = "Will ask when used"
            }
        }
    }

    /// Query (without prompting) whether we're allowed to send Apple events to `bundleId`.
    private static func automationStatus(_ bundleId: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return OSStatus(errAEEventNotPermitted) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
    }

    @objc private func openAccess() {
        // Can't grant TCC ourselves — prompt (adds us to the list) then deep-link the pane.
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contactsAction() {
        // Undecided → trigger the system prompt; already decided → open the pane to flip it.
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            ContactNames.shared.requestAccess()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAutomation() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func selectCurrentTrigger() {
        let cur = UserDefaults.standard.string(forKey: "triggerKey") ?? "leftOpt"
        if cur == "custom" {
            triggerPopup.selectItem(withTitle: customTitle)
        } else if let k = TriggerKey(rawValue: cur), let idx = TriggerKey.allCases.firstIndex(of: k) {
            triggerPopup.selectItem(at: idx)
        } else {
            triggerPopup.selectItem(at: 0)
        }
    }
    @objc private func pickTrigger(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? ""
        if title == customTitle {
            UserDefaults.standard.set("custom", forKey: "triggerKey")
        } else if let key = TriggerKey.allCases.first(where: { $0.label == title }) {
            UserDefaults.standard.set(key.rawValue, forKey: "triggerKey")
        }
        syncNote()
    }

    private func updateEdgeLabel() {
        edgeBandLabel.stringValue = String(format: "Band: %.0f%% – %.0f%% from top", edgeRange.low, edgeRange.high)
    }
    private func syncEdge() {
        edgeRange.enabled = UserDefaults.standard.bool(forKey: "edgeTrigger")
        updateEdgeLabel()
    }
    @objc private func toggleEdge(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "edgeTrigger")
        syncEdge()
    }
    @objc private func toggleContexts(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showContexts")
    }
    @objc private func toggleAILabel(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "ctxAILabeling")
    }
    @objc private func toggleFavicon(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "faviconLookup")
    }
    @objc private func toggleMenuIcon(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showMenuIcon")
        menuController.applyVisibility()
    }
    @objc private func toggleAutoUpdate(_ sender: NSButton) {
        updater.automaticallyChecksForUpdates = sender.state == .on
    }
    @objc private func toggleAutoInstall(_ sender: NSButton) {
        updater.automaticallyDownloadsUpdates = sender.state == .on
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            FileHandle.standardError.write("login item toggle failed: \(error)\n".data(using: .utf8)!)
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off   // revert to reality
        }
    }

    @objc private func quit() {
        let a = NSAlert()
        a.messageText = "Quit Jay?"
        a.informativeText = "The shortcut will stop working until you reopen the app."
        a.alertStyle = .warning
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    func show() {
        selectCurrentTrigger()
        recorder.currentLabel = UserDefaults.standard.string(forKey: "hotkeyLabel") ?? "Click, then press your shortcut"
        loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menuIconToggle.state = UserDefaults.standard.bool(forKey: "showMenuIcon") ? .on : .off
        contextsToggle.state = UserDefaults.standard.bool(forKey: "showContexts") ? .on : .off
        aiLabelToggle.state = UserDefaults.standard.bool(forKey: "ctxAILabeling") ? .on : .off
        autoUpdateToggle.state = updater.automaticallyChecksForUpdates ? .on : .off
        autoInstallToggle.state = updater.automaticallyDownloadsUpdates ? .on : .off
        syncNote()
        updatePermissions()
        // Poll while open — the user may grant/revoke in System Settings live.
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePermissions()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()   // accessory app: raise above other apps even when we're not frontmost
        centerOnActiveScreen()          // place LAST so ordering/restoration can't override it
    }

    // Center the window on the screen under the cursor (the monitor you clicked from), else main.
    private func centerOnActiveScreen() {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { window.center(); return }
        let s = window.frame.size
        let x = min(max(vf.minX, vf.midX - s.width / 2), vf.maxX - s.width)
        let yWanted = vf.midY - s.height / 2 + s.height * 0.08
        let y = min(max(vf.minY, yWanted), vf.maxY - s.height)   // clamp fully on-screen
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowWillClose(_ notification: Notification) {
        accessTimer?.invalidate(); accessTimer = nil
    }
}
