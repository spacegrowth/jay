import AppKit
import ApplicationServices
import ServiceManagement

// Jay — app entry + global trigger.
// Double-tap an Option key to toggle a non-activating panel listing tabs/sessions
// across running adapter apps. Incidental ⌥ use (⌥e, ⌥-click) won't fire it. Type
// to filter, arrows to move, Enter to switch, Esc to dismiss. Side (left/right ⌥)
// is set from the menu-bar item. See Adapters.swift / SwitcherPanel.swift /
// Trigger.swift.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)              // no Dock icon

// single-instance: a new launch wins — terminate any older copies of ourselves.
let BUNDLE_ID = "com.jaymac.jay"
for other in NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE_ID)
        where other != NSRunningApplication.current {
    other.forceTerminate()
}

// The global key monitor needs Accessibility; prompt if not yet granted.
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

// Contacts: resolve Messages phone/email handles → names. Prompts once, builds its map in the
// background; denied/undecided just falls back to formatted numbers (best-effort).
ContactNames.shared.requestAccess()

// Defaults (only applied if the user hasn't set them). Edge summon ON by default; band = % from top.
UserDefaults.standard.register(defaults: ["edgeTrigger": true, "edgeBandTop": 3.0, "edgeBandBottom": 55.0, "showMenuIcon": true, "showContexts": true, "faviconLookup": true])

// First launch only: enable "open at login" once. Honors the user turning it off later.
if !UserDefaults.standard.bool(forKey: "didInitLoginItem") {
    UserDefaults.standard.set(true, forKey: "didInitLoginItem")
    try? SMAppService.mainApp.register()
}

let settings = SettingsPanel()
let switcher = SwitcherPanel()
switcher.onOpenSettings = { settings.show() }
// trigger source for the usage log: the configured keyboard trigger (preset name or "custom")
let trigger = HoldCommand { switcher.toggle(source: UserDefaults.standard.string(forKey: "triggerKey") ?? "leftOpt") }
let edgeWatcher = LeftEdgeWatcher { screen in switcher.summonAtEdge(screen) }

// Menu-bar icon = the app. Left-click summons the panel (same as the shortcut) — a
// reliable fallback if the hotkey isn't working. Right-click (or ⌃-click) opens a menu
// with Preferences and Quit. The icon can be hidden from Preferences.
final class MenuController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    override init() {
        super.init()
        // Menu-bar mark: the Jay glyph (template PNG in the bundle), falling back to an SF Symbol.
        if let p = Bundle.main.path(forResource: "menubar-glyph", ofType: "png"),
           let logo = NSImage(contentsOfFile: p) {
            logo.isTemplate = true
            logo.size = NSSize(width: 18, height: 18)
            item.button?.image = logo
        } else if let fallback = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Jay") {
            fallback.isTemplate = true
            item.button?.image = fallback
        } else {
            item.button?.title = "⧉"
        }
        item.button?.target = self
        item.button?.action = #selector(click)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyVisibility()
    }
    @objc func click() {
        let e = NSApp.currentEvent
        let isRight = e?.type == .rightMouseUp || (e?.modifierFlags.contains(.control) ?? false)
        if isRight { showMenu() } else { switcher.toggle(source: "menu") }
    }
    private func showMenu() {
        let menu = NSMenu()
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPrefs), keyEquivalent: ",")
        prefs.target = self
        let quit = NSMenuItem(title: "Quit Jay", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(prefs); menu.addItem(.separator()); menu.addItem(quit)
        item.menu = menu                     // assign just for this pop, then clear so left-click still summons
        item.button?.performClick(nil)
        item.menu = nil
    }
    // Defer to the next run-loop tick so the status menu's tracking loop has fully
    // exited — otherwise activate()/orderFront mid-tracking leaves the window behind.
    @objc private func openPrefs() { DispatchQueue.main.async { settings.show() } }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applyVisibility() { item.isVisible = UserDefaults.standard.bool(forKey: "showMenuIcon") }
}
let menuController = MenuController()

// First run: if Accessibility isn't granted, show a window that tracks the permission live
// (red → green) so the user gets clear confirmation instead of a dead-end instruction.
Onboarding.shared.showIfNeeded()

FileHandle.standardError.write(
    "Jay ready — double-tap ⌥ (Accessibility trusted: \(trusted))\n"
        .data(using: .utf8)!)

app.run()
