import AppKit
import ApplicationServices

/// First-run window. Jay's hotkey + screen-edge summon need Accessibility, and a plain
/// "go enable it" instruction is a dead end — so this window shows the permission status
/// LIVE (red → green) and flips to "you're set" the moment macOS grants it. No guessing.
final class Onboarding: NSObject {
    static let shared = Onboarding()

    private var window: NSWindow?
    private var timer: Timer?
    private var dot = NSImageView()
    private var statusLabel = NSTextField(labelWithString: "")
    private var actionButton = NSButton(title: "", target: nil, action: nil)
    private var granted = false

    /// Show only when Accessibility isn't granted yet (called on launch).
    func showIfNeeded() {
        // Show on first run (to offer plugins) or whenever Accessibility still isn't granted.
        if !AXIsProcessTrusted() || !UserDefaults.standard.bool(forKey: "onboardingDone") { show() }
    }

    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }

        let heading = NSTextField(labelWithString: "One quick step to finish")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        let blurb = NSTextField(wrappingLabelWithString:
            "Jay summons every tab, session, and window with a hotkey (⌘K), a tap of “/”, or a push into the left screen edge.\n\nmacOS needs you to allow Jay under Accessibility for those to work.")
        blurb.font = .systemFont(ofSize: 13); blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 380

        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.imageScaling = .scaleProportionallyDown
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let statusRow = NSStackView(views: [dot, statusLabel])
        statusRow.orientation = .horizontal; statusRow.spacing = 8; statusRow.alignment = .centerY

        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(primaryTapped)

        // Built-in plugins are bundled + off by default — offer them here so the user turns on
        // the ones they use (the guided "want to enable this?" step the installer can't do).
        let builtIns = (PluginHost.builtInRoot.map { PluginHost.discover(in: $0, source: .builtIn) } ?? [])
            .sorted { $0.manifest.name < $1.manifest.name }
        let plugins = pluginChecklist(builtIns)

        let stack = NSStackView(views: [heading, blurb, statusRow, plugins, actionButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(20, after: blurb)
        stack.setCustomSpacing(20, after: plugins)

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -26),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300 + CGFloat(builtIns.count) * 46),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Jay"
        w.contentView = root
        w.isReleasedWhenClosed = false
        w.center()
        window = w

        refresh()                                   // paint initial state
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Reflect the live Accessibility state: red "Not enabled" → green "Enabled ✓".
    private func refresh() {
        granted = AXIsProcessTrusted()
        dot.contentTintColor = granted ? .systemGreen : .systemOrange
        statusLabel.stringValue = granted ? "Accessibility enabled — you're all set" : "Accessibility: not enabled yet"
        statusLabel.textColor = granted ? .systemGreen : .labelColor
        actionButton.title = granted ? "Start using Jay" : "Open Accessibility Settings"
    }

    @objc private func primaryTapped() {
        if granted { finish(); return }
        // Prompt + jump straight to the Accessibility list; the timer keeps polling.
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")   // don't re-prompt for plugins next launch
        timer?.invalidate(); timer = nil
        window?.close(); window = nil
    }

    // ── first-run plugins checklist ──

    /// A "turn on the plugins you use" section listing each bundled built-in with a toggle.
    /// Empty (zero height) if no built-ins are bundled.
    private func pluginChecklist(_ builtIns: [LoadedPlugin]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical; container.alignment = .leading; container.spacing = 8
        guard !builtIns.isEmpty else { return container }
        let title = NSTextField(labelWithString: "Turn on the plugins you use")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        container.addArrangedSubview(title)
        for p in builtIns { container.addArrangedSubview(pluginToggleRow(p)) }
        return container
    }

    private func pluginToggleRow(_ p: LoadedPlugin) -> NSView {
        let name = NSTextField(labelWithString: p.manifest.name); name.font = .systemFont(ofSize: 13)
        let hint = NSTextField(labelWithString: pluginHint(p)); hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let col = NSStackView(views: [name, hint]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
        col.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sw = NSSwitch(); sw.state = PluginHost.isEnabled(p) ? .on : .off
        sw.target = self; sw.action = #selector(togglePlugin(_:)); sw.identifier = NSUserInterfaceItemIdentifier(p.id)
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [col, spacer, sw]); row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 384).isActive = true   // fill the window's content width
        return row
    }

    private func pluginHint(_ p: LoadedPlugin) -> String {
        switch p.manifest.name {
        case "Terminal": return "Apple Terminal tabs · asks for Automation the first time"
        case "VS Code":  return "Editor tabs · also needs the bridge extension in VS Code"
        default:         return p.manifest.targetApp.map { "\($0) items" } ?? "Adds \(p.manifest.name)"
        }
    }

    @objc private func togglePlugin(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        PluginHost.setEnabled(id, source: .builtIn, sender.state == .on)
    }
}
