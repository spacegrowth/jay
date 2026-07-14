import AppKit
import ApplicationServices

/// Summons when the cursor presses a PHYSICAL vertical edge of its screen (a real wall you can
/// shove against), within a vertical band, after a short dwell so casual passes don't fire.
///
/// Which edge is physical depends on the monitor layout:
///   • leftmost / single monitor → its LEFT edge (panel slides in from the left),
///   • a monitor with a screen to its left (e.g. the second monitor) → its RIGHT edge
///     (panel mirrors and slides in from the right),
///   • a monitor with screens on BOTH sides → no physical vertical edge → use the hotkey.
/// The internal boundary between two monitors is never a trigger (no wall → unreliable).
///
/// Opt-in + configurable via UserDefaults (edgeTrigger / edgeBandTop / edgeBandBottom). Uses a
/// LISTEN-ONLY CGEvent tap so it keeps seeing moves even while our own app is active with no window.
final class LeftEdgeWatcher {
    private let action: (NSScreen) -> Void
    private var tap: CFMachPort?
    private var dwell: DispatchWorkItem?
    private var inZone = false
    private let dwellDelay: CFTimeInterval = 0.18

    private var retry: Timer?

    init(action: @escaping (NSScreen) -> Void) {
        self.action = action
        arm()
    }

    /// Create the listen-only tap. Only permitted once Accessibility is granted, so if it fails
    /// (Jay launched before the grant), poll and retry — the edge self-heals when Accessibility is
    /// granted, no relaunch needed.
    private func arm() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<LeftEdgeWatcher>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: cb,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { scheduleRetry(); return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        retry?.invalidate(); retry = nil
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() { self.arm() }
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        evaluate()
        return Unmanaged.passUnretained(event)
    }

    private enum Side { case left, right }

    private func evaluate() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "edgeTrigger") else { reset(); return }
        let p = NSEvent.mouseLocation                                   // global coords, origin bottom-left
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { reset(); return }
        let f = screen.frame
        let top = max(0, min(100, d.double(forKey: "edgeBandTop")))
        let bot = max(0, min(100, d.double(forKey: "edgeBandBottom")))
        let yFromTop = (f.maxY - p.y) / f.height * 100                  // 0 = top, 100 = bottom
        guard top < bot, yFromTop >= top, yFromTop <= bot else { reset(); return }

        // Trigger on the SAME edge the panel appears at (Preferences ▸ Panel side), so the summon
        // gesture matches where Jay shows up. Honor the preference, but only where that edge is a real
        // outer wall — if the preferred side abuts another monitor (a seam), fall back to the exposed
        // side; if both sides are seams (sandwiched), there's no wall to push into.
        let preferRight = d.string(forKey: "panelSide") == "right"
        let leftWall = !hasNeighbor(of: screen, on: .left)
        let rightWall = !hasNeighbor(of: screen, on: .right)
        let onRight: Bool
        if preferRight {
            if rightWall { onRight = true } else if leftWall { onRight = false } else { reset(); return }
        } else {
            if leftWall { onRight = false } else if rightWall { onRight = true } else { reset(); return }
        }
        let atEdge = onRight ? (p.x >= f.maxX - 1.5) : (p.x <= f.minX + 1.5)

        if atEdge {
            if !inZone {                                               // entering the zone → arm the dwell (fires once)
                inZone = true
                let w = DispatchWorkItem { [weak self] in
                    guard let self = self, self.inZone else { return }
                    self.action(screen)
                }
                dwell = w
                DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay, execute: w)
            }
        } else {
            reset()
        }
    }

    /// Whether another screen sits immediately on the given side of `s` (sharing that edge with
    /// vertical overlap). Used to tell a real outer wall from an internal monitor boundary.
    private func hasNeighbor(of s: NSScreen, on side: Side) -> Bool {
        let f = s.frame
        return NSScreen.screens.contains { o in
            guard o !== s, o.frame.minY < f.maxY, o.frame.maxY > f.minY else { return false }   // y overlap
            switch side {
            case .left:  return abs(o.frame.maxX - f.minX) < 2          // o's right edge meets our left
            case .right: return abs(o.frame.minX - f.maxX) < 2          // o's left edge meets our right
            }
        }
    }

    private func reset() { inZone = false; dwell?.cancel(); dwell = nil }
}
