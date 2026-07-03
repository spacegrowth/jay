import AppKit
import ApplicationServices

/// The summon shortcut: a double-tap of one modifier key. Configurable.
enum TriggerKey: String, CaseIterable {
    case leftOpt, rightOpt, leftCmd, rightCmd

    /// virtual keycode of the key on the press edge.
    var keycode: Int64 {
        switch self { case .leftOpt: return 58; case .rightOpt: return 61
                      case .leftCmd: return 55; case .rightCmd: return 54 }
    }
    /// the modifier flag this key sets.
    var mask: CGEventFlags { (self == .leftOpt || self == .rightOpt) ? .maskAlternate : .maskCommand }

    var label: String {
        switch self {
        case .leftOpt:  return "Double-tap Left ⌥"
        case .rightOpt: return "Double-tap Right ⌥"
        case .leftCmd:  return "Double-tap Left ⌘"
        case .rightCmd: return "Double-tap Right ⌘"
        }
    }
    var isCommand: Bool { mask == .maskCommand }

    static var current: TriggerKey {
        TriggerKey(rawValue: UserDefaults.standard.string(forKey: "triggerKey") ?? "") ?? .leftOpt
    }
}

/// A single-press custom shortcut (modifiers + key), as an alternative to the
/// double-tap presets. We normalise modifiers into our own small bitmask so the
/// recorder (NSEvent flags) and the matcher (CGEvent flags) agree exactly.
enum Hotkey {
    static let cmd = 1, opt = 2, ctrl = 4, shift = 8

    static func mods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= cmd }; if f.contains(.option) { m |= opt }
        if f.contains(.control) { m |= ctrl }; if f.contains(.shift) { m |= shift }
        return m
    }
    static func mods(_ f: CGEventFlags) -> Int {
        var m = 0
        if f.contains(.maskCommand) { m |= cmd }; if f.contains(.maskAlternate) { m |= opt }
        if f.contains(.maskControl) { m |= ctrl }; if f.contains(.maskShift) { m |= shift }
        return m
    }

    // Named keys whose character isn't printable, so the label reads cleanly.
    static let named: [Int: String] = [
        49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 116: "⇞", 121: "⇟", 115: "↖", 119: "↘",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]

    static func keyName(_ code: Int, chars: String?) -> String {
        if let n = named[code] { return n }
        if let c = chars?.first, c.isLetter || c.isNumber || (c.isASCII && !c.isWhitespace) {
            return String(c).uppercased()
        }
        return "Key \(code)"
    }
    static func label(code: Int, mods m: Int, chars: String?) -> String {
        var s = ""
        if m & ctrl != 0 { s += "⌃" }; if m & opt != 0 { s += "⌥" }
        if m & shift != 0 { s += "⇧" }; if m & cmd != 0 { s += "⌘" }
        return s + keyName(code, chars: chars)
    }
    /// A key is a safe bare trigger only if it carries a modifier or is a function/named
    /// key — otherwise it would fire on every keystroke while typing.
    static func acceptable(code: Int, mods m: Int) -> Bool { m != 0 || named[code] != nil }
}

/// Fires on a DOUBLE-TAP of the configured modifier key: press and release it twice
/// within a short window, with nothing else pressed in between. Modifier keys don't
/// print, so a double-tap is unambiguous — and incidental use (⌥e, ⌘C, ⌥-click)
/// never fires because any other key/click resets the sequence. Needs Accessibility.
final class HoldCommand {
    private let threshold: CFTimeInterval = 0.30
    private let action: () -> Void
    private var tap: CFMachPort?
    private var lastTap: CFTimeInterval = -1   // time of the previous clean press of the trigger key

    private let allMods: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]

    init(action: @escaping () -> Void) {
        self.action = action
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HoldCommand>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        // LISTEN-ONLY: we only observe to detect the double-tap; we never modify or
        // swallow events. A passive tap is delivered event copies asynchronously, so
        // the window server never blocks input on us — it physically cannot freeze
        // the keyboard/mouse even if this process hangs or loses Accessibility.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: cb,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                FileHandle.standardError.write("HoldCommand: tapCreate FAILED\n".data(using: .utf8)!)
                return
            }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Only re-arm if we're still trusted — never fight the system after the
            // user revokes Accessibility (that path is what froze input before).
            if let tap = tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Custom single-press shortcut: match the recorded chord on key-down and fire.
        if UserDefaults.standard.string(forKey: "triggerKey") == "custom" {
            if type == .keyDown, UserDefaults.standard.object(forKey: "hotkeyCode") != nil {
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if code == UserDefaults.standard.integer(forKey: "hotkeyCode")
                    && Hotkey.mods(event.flags) == UserDefaults.standard.integer(forKey: "hotkeyMods") {
                    DispatchQueue.main.async { self.action() }
                }
            }
            return Unmanaged.passUnretained(event)   // ignore the double-tap path entirely
        }

        // Any key or mouse click breaks a would-be double-tap (⌥e, ⌘C, ⌥-click…).
        if type == .keyDown || type == .leftMouseDown ||
           type == .rightMouseDown || type == .otherMouseDown {
            lastTap = -1
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let key = TriggerKey.current            // read live, so settings apply instantly
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let f = event.flags
            // our modifier set, and NO other modifier held (a clean solo tap)?
            let others = allMods.filter { $0 != key.mask }
            let alone = f.contains(key.mask) && !others.contains { f.contains($0) }

            if code == key.keycode && alone {
                let now = CACurrentMediaTime()
                if now - lastTap < threshold {
                    lastTap = -1
                    DispatchQueue.main.async { self.action() }
                } else {
                    lastTap = now
                }
            } else if code == key.keycode && !f.contains(key.mask) {
                // release edge — ignore, keep the timing window open for the second tap
            } else {
                // a different modifier engaged → not a clean tap sequence
                lastTap = -1
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
