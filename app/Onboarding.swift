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
    func showIfNeeded() { if !AXIsProcessTrusted() { show() } }

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

        let stack = NSStackView(views: [heading, blurb, statusRow, actionButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(20, after: blurb)

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -26),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
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
        timer?.invalidate(); timer = nil
        window?.close(); window = nil
    }
}
